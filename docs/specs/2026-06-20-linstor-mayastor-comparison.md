# LINSTOR/Piraeus vs Mayastor 3-Way Benchmark Design

## Goal

Produce decision-quality evidence for choosing between OpenEBS Replicated PV Mayastor and LINSTOR/Piraeus for small RWO app-state PersistentVolumes on the homelab k3s cluster.

The evaluation will run a real 3-node, 3-replica benchmark on homelab hardware. It must measure both performance and operational fit:

- replicated write/read latency and throughput for app-state style PVCs
- setup complexity on NixOS hosts
- Kubernetes/GitOps manifest complexity
- degraded-node and recovery behavior
- cleanup/rollback effort
- monitoring signals required before any real workload migration

## Decision

Run a staged benchmark of both backends on the real homelab cluster before selecting a storage backend.

Use these three storage nodes for the first benchmark cohort:

| Node | IP | Reason |
| --- | --- | --- |
| `dauwalter` | `192.168.1.100` | NVMe-only host; simple storage role |
| `fordyce` | `192.168.1.102` | NVMe-only host; simple storage role |
| `selassie` | `192.168.1.104` | NVMe plus SATA `/srv/data`; avoids `kipsang`'s NFS role |

Do not use `kipsang` for the initial benchmark because it exports `/srv/data` over NFS. Do not use `walmsley` unless one of the selected nodes is unavailable.

## Constraints

- Kubernetes resource changes must be represented in the GitOps repository and reconciled by ArgoCD.
- Do not use direct-write workstation commands such as `kubectl apply`, `kubectl patch`, `kubectl delete`, or `helm upgrade` against the homelab cluster.
- Read-only cluster inspection is allowed for measurement collection, for example `kubectl get`, `kubectl describe`, and `kubectl logs`.
- Benchmark PVCs are disposable and must not contain production data.
- Existing Longhorn-backed production PVCs remain untouched.
- Mayastor and LINSTOR/Piraeus should be active one backend at a time unless resource isolation has been explicitly verified.
- Host disk restructuring is destructive and must remain rolling, one node at a time, with operator confirmation and recovery access.

## Source Documentation Checked

- OpenEBS 4.5.x prerequisites for Replicated PV Mayastor: `nvme-tcp`, ext4/xfs, hugepages, and optional `nvme_core.multipath=Y` for HA.
- OpenEBS Replicated PV Mayastor DiskPool documentation: each DiskPool is node-owned and uses one whole block device referenced by a stable device link.
- OpenEBS Replicated PV Mayastor StorageClass documentation: a three-replica class uses `provisioner: io.openebs.csi-mayastor`, `protocol: nvmf`, and `repl: "3"`.
- Piraeus `LinstorSatelliteConfiguration` reference: storage pools can be `lvmPool` or `lvmThinPool`; LVM thin pools can reference an existing `volumeGroup` and `thinPool`.
- Piraeus replicated-volume tutorial: replicated StorageClasses use `provisioner: linstor.csi.linbit.com`, `linstor.csi.linbit.com/storagePool`, and `linstor.csi.linbit.com/placementCount`.

## Backend Comparison Focus

| Dimension | Mayastor | LINSTOR/Piraeus | Benchmark implication |
| --- | --- | --- | --- |
| Data path | NVMe-oF target with synchronous replicas | DRBD-backed replicated block devices via LINSTOR CSI | fio must capture latency percentiles, not only throughput |
| Pool model | `DiskPool` per node, each consuming one whole block device | LINSTOR storage pool backed by LVM/LVMThin/ZFS/file pools | NixOS storage layout differs and is part of the test |
| LVM fit | Uses a raw LV as the whole DiskPool device; stable by-id path required | Native named `lvmPool`/`lvmThinPool` support | LINSTOR should be evaluated for simpler LVM integration |
| Host prerequisites | `nvme_tcp`, hugepages, optional `nvme_core.multipath=Y`, Mayastor node label | DRBD kernel module and userspace tooling, LVM/thin tooling | NixOS kernel/module lifecycle risk is a core comparison item |
| 3-way setting | StorageClass `repl: "3"` | StorageClass `placementCount: "3"` | Both tests must provision exactly three replicas |
| Failure behavior | Mayastor volume/nexus rebuild and NVMe path recovery | DRBD quorum/split-brain/reconnect behavior | Include one controlled degraded-node observation per backend |
| Operational concern | Raw block pool sizing and hugepage reservation | DRBD module versioning and thin-pool monitoring | Setup notes count toward final recommendation |

## Host Storage Shape

The benchmark should use comparable disposable NVMe-backed capacity on each of the three selected nodes. The target shape is:

- a common NVMe LVM volume group, for example `vg-nvme`
- a Mayastor raw LV per node, for example `mayastor-bench`, exposed as a stable `/dev/disk/by-id/dm-name-vg--nvme-mayastor--bench` path
- a LINSTOR thin pool per node, for example `linstor-bench-thin`, under the same NVMe-backed volume group
- equal data capacity for both backends on every benchmark node

Recommended initial size: 30 GiB per backend per node if free space permits. If any selected node cannot spare that capacity safely, reduce both backends to the same smaller size rather than changing only one backend.

The benchmark should prefer declaring both disposable areas in Nix/disko during the same rolling host restructure. This avoids rebuilding the same node twice and keeps the A/B comparison on the same underlying disk layout. Only one Kubernetes storage backend should consume its corresponding pool during a benchmark phase.

## NixOS Changes to Evaluate

### Common benchmark host module

Create or extend a shared NixOS storage-benchmark module with:

- explicit enable flags for benchmark-participating nodes
- optional node labels for Mayastor and LINSTOR/Piraeus selection
- LVM tooling required by the chosen layouts
- comments warning that benchmark LVs are disposable

### Mayastor-specific host requirements

- Load `nvme_tcp` on nodes that may mount Mayastor volumes.
- Reserve at least 2 GiB of 2 MiB hugepages on nodes that may run Mayastor io-engine pods.
- Set `nvme_core.multipath=Y` if HA multipath is enabled for the pilot class.
- Apply `openebs.io/engine=mayastor` only after the node has the validated Mayastor raw LV.

### LINSTOR/Piraeus-specific host requirements

- Provide a DRBD 9 kernel module compatible with the active NixOS kernel.
- Provide LINSTOR/DRBD userspace and LVM tooling as required by Piraeus satellite containers and host interaction.
- Validate current pinned nixpkgs versions before implementation:
  - `pkgs.drbd` userspace was previously observed as `9.33.0`.
  - `boot.kernelPackages.drbd` was previously observed as `9.2.16` for `linux-6.18.35`.
- Configure and monitor the LVM thin pool used for the LINSTOR storage pool.

## GitOps Changes to Evaluate

GitOps manifests should live in the homelab Kubernetes repository, not as direct cluster mutations from a workstation.

For Mayastor:

- ArgoCD Application or chart definition for OpenEBS Replicated PV Mayastor.
- Node-restricted DiskPool manifests for `dauwalter`, `fordyce`, and `selassie`.
- A benchmark StorageClass similar to:
  - `provisioner: io.openebs.csi-mayastor`
  - `protocol: nvmf`
  - `repl: "3"`
  - `volumeBindingMode: WaitForFirstConsumer`
- Disposable benchmark PVC and fio Job manifests.

For LINSTOR/Piraeus:

- ArgoCD Application or chart definition for the Piraeus operator.
- `LinstorSatelliteConfiguration` selecting only `dauwalter`, `fordyce`, and `selassie` for the benchmark storage pool.
- A benchmark StorageClass similar to:
  - `provisioner: linstor.csi.linbit.com`
  - `linstor.csi.linbit.com/storagePool: <benchmark-pool>`
  - `linstor.csi.linbit.com/placementCount: "3"`
  - `volumeBindingMode: WaitForFirstConsumer`
- Disposable benchmark PVC and fio Job manifests.

## Benchmark Workloads

Each backend should run the same fio suite against a fresh disposable RWO PVC. Run a warm-up pass, then three measured passes per profile. Use fio JSON output so results can be aggregated mechanically.

Recommended PVC size: 10 GiB. Recommended fio file size: 4 GiB. If capacity is reduced, keep the same values across both backends.

| Profile | fio intent | Why it matters |
| --- | --- | --- |
| `seq-write-1m` | 1 MiB sequential write, moderate queue depth | Baseline replicated write bandwidth |
| `seq-read-1m` | 1 MiB sequential read, moderate queue depth | Baseline read path and cache behavior |
| `rand-write-4k` | 4 KiB random write, queue depth 32 | Worst-case replicated small writes |
| `rand-read-4k` | 4 KiB random read, queue depth 32 | Small-state read latency |
| `randrw-4k-70r30w` | 4 KiB mixed random read/write | Common app-state blend |
| `sync-write-4k` | 4 KiB write with fsync/fdatasync at queue depth 1 | Database-like durability latency |

Collect at minimum:

- IOPS
- bandwidth MiB/s
- mean latency
- p50/p95/p99/p99.9 completion latency
- fio error count
- pod node
- PVC/PV name and StorageClass
- backend volume health before and after each profile
- CPU and memory pressure observations for storage pods if metrics are available

## Benchmark Execution Model

Use one GitOps-managed fio Job per backend run. The Job should:

1. mount the benchmark PVC at `/volume`
2. run all fio profiles sequentially
3. write JSON results to `/volume/results/<backend>/<timestamp>/`
4. print a compact summary to stdout
5. exit non-zero if any fio profile reports errors

Because Kubernetes Jobs do not rerun when a completed Job remains unchanged, reruns should use a new Job name or a GitOps hook policy. Do not rerun by deleting Jobs directly from the workstation.

## Recovery Observation

After baseline fio passes, run one controlled degraded-node observation for each backend:

1. Confirm the benchmark volume is healthy and has three replicas.
2. Stop or reboot one selected storage node during an idle benchmark window.
3. Observe whether the PVC remains attachable or becomes temporarily unavailable.
4. Restore the node.
5. Measure time until the backend reports healthy three-replica state again.
6. Run `sync-write-4k` once after recovery to detect severe latency regression.

This is not a destructive failure test. It is a practical homelab recovery observation. Operator confirmation is required before any drain, reboot, or service stop.

## Acceptance Criteria

A backend remains a viable candidate only if all of these are true:

- It can be installed and reconciled through GitOps without direct cluster writes.
- It can provision a 10 GiB RWO PVC with exactly three replicas across `dauwalter`, `fordyce`, and `selassie`.
- fio completes all benchmark profiles with zero data-path errors.
- The sync-write profile has acceptable tail latency for small app-state workloads; exact winner is based on relative p95/p99 compared with the other backend.
- A single storage-node outage does not cause unrecoverable volume state or manual data repair.
- The backend exposes enough health metrics or CLI/status information to operate it safely.
- Cleanup is clear and does not threaten Longhorn-backed production PVCs.

## Recommendation Criteria

Prefer LINSTOR/Piraeus if:

- DRBD kernel/module handling is reliable on the pinned NixOS kernel,
- LVM/LVMThin integration is materially simpler than Mayastor's raw DiskPool device model,
- 3-replica sync-write latency is comparable to or better than Mayastor,
- degraded-node recovery is understandable and observable.

Prefer Mayastor if:

- DRBD module management is fragile or operationally unattractive on NixOS,
- Mayastor's host prerequisites are straightforward after the existing module work,
- fio shows meaningfully better small-write tail latency,
- DiskPool lifecycle and recovery are simpler than LINSTOR/Piraeus in practice.

Defer both if:

- either backend requires unsafe direct cluster mutations,
- both have poor recovery behavior on a one-node outage,
- monitoring is insufficient to detect degraded replicas or pool exhaustion,
- setup requires more invasive disk changes than the homelab benefit justifies.

## Current Mayastor Plan Impact

The existing Mayastor NVMe LVM plan remains useful for:

- rolling one-node-at-a-time destructive host restructure
- raw LV validation before adding Kubernetes DiskPools
- shared host prerequisite module structure
- Mayastor `repl: "3"` StorageClass shape
- keeping Longhorn as the default storage class during evaluation

The plan should be paused or generalized for:

- naming raw LVs as permanent app-state pools before the benchmark decision
- assuming Mayastor-specific `nvme_tcp`, hugepages, multipath, and node labels apply to the final backend
- committing to the DiskPool-by-id model before LINSTOR/Piraeus is tested

If the benchmark selects LINSTOR/Piraeus, Mayastor-specific host options should either be removed or converted into backend-specific toggles so they are not enabled on nodes that do not run Mayastor.

## Rollout Checklist

1. Verify the worktree is clean and the current branch is task-specific.
2. Confirm no selected node has production data on the planned disposable NVMe space.
3. Add benchmark LVM layout for `dauwalter`, `fordyce`, and `selassie`.
4. Rebuild/reinstall one selected node at a time with operator confirmation.
5. Verify each node rejoins k3s and exposes the expected benchmark LVs/thin pool.
6. Deploy Mayastor GitOps manifests for the benchmark scope only.
7. Run Mayastor 3-replica fio benchmark and recovery observation.
8. Remove or disable Mayastor benchmark manifests through GitOps.
9. Deploy LINSTOR/Piraeus GitOps manifests for the benchmark scope only.
10. Run LINSTOR/Piraeus 3-replica fio benchmark and recovery observation.
11. Aggregate fio JSON and operational notes into a final comparison table.
12. Choose backend, then write a backend-specific implementation plan.

## Implementation Defaults

Use these defaults when writing the implementation plan unless verification shows a selected node cannot support them safely:

- Benchmark backend capacity: 30 GiB per backend per selected node.
- Benchmark PVC size: 10 GiB.
- fio working file size: 4 GiB.
- GitOps repository: `/home/roche/homelab-k8s`.
- NixOS host repository/worktree: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm`.
- fio runner image: use a pinned digest during implementation; the initial candidate is the image used by the OpenEBS fio example, `nixery.dev/shell/fio`.
- Mayastor HA multipath: enable for the benchmark only if `nvme_core.multipath=Y` is applied and validated on all three selected nodes first.
- LINSTOR pool type: test LVM thin first because it best matches the desired app-state pool model.
