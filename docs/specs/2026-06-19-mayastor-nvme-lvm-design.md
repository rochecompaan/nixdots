# Mayastor NVMe LVM App-State Pool Design

## Goal

Prepare the homelab NixOS cluster for an OpenEBS Replicated PV Mayastor pilot that uses small, fast, NVMe-backed raw block devices for app-state PersistentVolumes without first disturbing the existing `/srv/data` SATA media/data layout.

The design intentionally accepts destructive per-node disk restructuring because the cluster has five hosts and can tolerate rolling reformat/rejoin work when only one node is rebuilt at a time.

## Current Cluster State

The Kubernetes cluster currently has five Ready NixOS k3s server/control-plane nodes:

| Node | IP | Existing NixOS disk layout relevant to this design |
| --- | --- | --- |
| `dauwalter` | `192.168.1.100` | NVMe root disk only in `hosts/dauwalter/disko.nix` |
| `kipsang` | `192.168.1.101` | NVMe root disk plus SATA `/srv/data` disk |
| `fordyce` | `192.168.1.102` | NVMe root disk only |
| `walmsley` | `192.168.1.103` | NVMe root disk plus SATA `/srv/data` disk |
| `selassie` | `192.168.1.104` | NVMe root disk plus SATA `/srv/data` disk |

The current cluster NixOS configs already enable k3s and open-iscsi on these nodes. They do not currently configure Mayastor-specific NVMe/TCP, hugepage, multipath, node-label, or DiskPool-ready raw block device settings.

## Mayastor Storage Requirement Interpretation

OpenEBS Mayastor DiskPools require exclusive use of a stable block device reference. They do not require the backing storage to be a whole physical disk, but the block device used by a DiskPool must not be mounted, formatted, partitioned further, or shared with another application.

Therefore a plain LVM logical volume is an acceptable pilot candidate if it is exposed as a stable `/dev/disk/by-id` path and treated as a raw, unformatted, unmounted device. The first pilot will use simple linear LVM LVs only. Thin LVs, snapshot LVs, RAID LVs, and shared filesystems are excluded from the initial pilot to keep failure modes simple.

## Design Choice

Use each host's NVMe disk as the first Mayastor app-state backing store by restructuring it under LVM:

```text
NVMe physical disk
├─ EFI system partition mounted at /boot
└─ LVM physical volume
   └─ volume group: vg-nvme
      ├─ root filesystem LV
      └─ mayastor-appstate LV, raw and unmounted
```

The Mayastor LV will be small relative to the full disk and reserved for small RWO app-state volumes. The exact size should be conservative enough to leave room for OS growth and Nix store churn while still large enough for pilot workloads. A practical initial target is 100 GiB per node unless a host's NVMe capacity requires a smaller size.

The SATA `/srv/data` disks on `kipsang`, `walmsley`, and `selassie` stay unchanged during this first phase. They can be revisited later for media/ZFS or bulk-storage work, but they are not part of the initial Mayastor app-state pilot.

## NixOS Configuration Shape

Each cluster host will move from a direct root partition layout to an LVM-backed NVMe layout in `hosts/<node>/disko.nix`.

Required properties for each node:

- The NVMe disk continues to be referenced by its existing stable `/dev/disk/by-id/...` path.
- `/boot` remains a normal EFI partition.
- The root filesystem is recreated on an LVM LV.
- The Mayastor app-state LV exists as a raw LVM logical volume.
- The Mayastor LV has no filesystem mountpoint in NixOS.
- The Mayastor DiskPool manifest references a stable device-mapper by-id path, preferably a deterministic `dm-name` or `dm-uuid` link observed after rebuilding the node.

Mayastor host prerequisites will be factored into a shared NixOS module or shared host snippet so all eligible nodes use consistent settings:

- Load `nvme_tcp` on nodes that may mount Mayastor volumes.
- Reserve 2 GiB of 2 MiB hugepages on nodes that may run Mayastor io-engine pods.
- Enable `nvme_core.multipath=Y` if the pilot StorageClass uses Mayastor HA multipath.
- Ensure XFS support is available if pilot PVC filesystems use XFS.
- Add node labels declaratively only after a node has been destructively rebuilt, rejoined the cluster, and exposes the raw Mayastor LV correctly.

## Kubernetes and GitOps Shape

Homelab Kubernetes changes remain GitOps-only. No workstation `kubectl apply`, `kubectl patch`, `kubectl delete`, or `helm upgrade` should mutate cluster resources directly.

Mayastor manifests should be added under the repository's ArgoCD-managed paths. The first GitOps phase should install Mayastor without replacing any existing default storage class. DiskPools should be added only for nodes that have completed the NixOS disk restructure and validation.

The first StorageClass should be a pilot class for small RWO app-state volumes:

- `protocol: nvmf`
- `repl: "3"` after at least three node DiskPools exist
- filesystem `xfs` or `ext4`, with XFS preferred only after host support is verified
- no thin provisioning for the first pilot unless capacity monitoring is in place

## Rollout Strategy

Roll out one node at a time. The cluster has five control-plane/etcd nodes, so one node can be drained/rebuilt/rejoined while the others continue serving the cluster.

Recommended order:

1. Rebuild `fordyce` first because it does not currently host a SATA `/srv/data` disk.
2. Rebuild `dauwalter` or another low-impact node second, taking care because `dauwalter` is the current `clusterInit`/server address anchor in the NixOS k3s configs.
3. Rebuild a third node to unlock Mayastor `repl: "3"` testing.
4. Add the remaining two nodes after the first three-node pilot passes.

For each node:

1. Confirm etcd/control-plane health before removing the node.
2. Drain or otherwise move workloads away through normal Kubernetes operations.
3. Apply the destructive NixOS disk layout for that host.
4. Rejoin k3s and confirm the node is Ready.
5. Confirm the Mayastor LV appears as a stable `/dev/disk/by-id/dm-*` device.
6. Only then add or enable the node's Mayastor DiskPool manifest and node label through GitOps.

## Validation Criteria

Before using any real app-state PVC, the pilot must prove:

- Each rebuilt node evaluates and builds with `nix build .#nixosConfigurations.<node>.config.system.build.toplevel`.
- The raw Mayastor LV exists and is not mounted.
- The raw Mayastor LV has a stable `/dev/disk/by-id` reference.
- Mayastor sees the device as available for a DiskPool.
- A disposable PVC provisions on the pilot StorageClass.
- A `repl: "3"` volume survives a non-primary node reboot.
- A workload using the disposable PVC can move after cordoning/rebooting its original node.
- A simulated full-cluster power recovery does not leave Mayastor in a worse recovery state than Longhorn.
- Metrics or alerts cover DiskPool capacity, degraded replicas, and unavailable volumes before critical workloads migrate.

## Non-Goals

This design does not migrate Jellyfin media, bulk object data, or database-primary storage to Mayastor.

This design does not replace Longhorn as the default storage class. Mayastor starts as a separate pilot storage class for low-risk small RWO app-state PVCs.

This design does not restructure the SATA `/srv/data` disks. Those disks remain available for later ZFS/media/bulk-data work.

## Risks and Mitigations

- **Risk: LVM LV support is not documented as a named Mayastor best-practice.** Mitigation: validate one node and one disposable DiskPool before restructuring all hosts.
- **Risk: Root disk restructuring is destructive.** Mitigation: rebuild only one node at a time and verify cluster health between nodes.
- **Risk: NVMe root and Mayastor app-state pools share a physical failure domain.** Mitigation: Mayastor replication spans nodes, and this pilot targets small app state rather than bulk data.
- **Risk: `dauwalter` is a bootstrap/server-address anchor.** Mitigation: avoid rebuilding it first and consider moving k3s clients to a stable load-balanced server address before or during the rollout.
- **Risk: hugepage reservation reduces general workload capacity.** Mitigation: reserve only on nodes intended to run Mayastor io-engine pods and monitor available memory after rollout.
