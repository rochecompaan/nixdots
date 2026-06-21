# Mayastor NVMe LVM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare all five homelab NixOS nodes to expose an unformatted NVMe-backed LVM logical volume for OpenEBS Mayastor app-state DiskPools.

**Architecture:** Add a shared NixOS module for Mayastor host prerequisites, then destructively restructure each node's NVMe disk under LVM one host at a time. Each node keeps `/boot`, moves `/` to an LVM root LV, and adds a raw `mayastor-appstate` LV that is never mounted by NixOS.

**Tech Stack:** NixOS, disko, LVM, k3s, OpenEBS Replicated PV Mayastor, nixos-anywhere, GitOps handoff for Kubernetes manifests.

---

## Scope and Safety Notes

This plan covers the `~/nixdots` NixOS side. It does not create OpenEBS or DiskPool Kubernetes manifests because this worktree is in the NixOS config repo, while the ArgoCD/GitOps tree is not present here. After at least one node exposes the raw LV, create a separate GitOps plan in the repo that owns the ArgoCD manifests.

Changing `hosts/<node>/disko.nix` does not repartition a live node through a normal `nixos-rebuild switch`. The destructive disk layout is applied during reinstall with `scripts/deploy-nixos.sh`, which wraps `nixos-anywhere`. Run that only during a maintenance window with console/recovery access.

Node draining is part of the approved maintenance flow for this rollout because it can be done from this repository with a local `.kubeconfig`. Drain and uncordon commands mutate node scheduling state, so every drain command in this plan requires typed human confirmation before it runs. The destructive `scripts/deploy-nixos.sh` command also requires its own separate typed confirmation.

Do not run direct GitOps resource mutations such as `kubectl apply`, `kubectl patch`, `kubectl delete`, or `helm upgrade` from the agent. The allowed Kubernetes write operations in this plan are limited to explicit node maintenance commands: `kubectl drain` before reinstall and `kubectl uncordon` after the reinstalled node is Ready.

The repo-local `.kubeconfig` must remain untracked. If `.kubeconfig` is not already ignored locally, run `printf '.kubeconfig\n' >> .git/info/exclude` before placing it at the worktree root.

No new automated tests are added for these static Nix config values. Verification is by `nix fmt`, host-specific `nix build`, `nix flake check`, and post-reinstall read-only device inspection.

## Files to Create or Modify

- Create: `modules/nixos/opt/mayastor/default.nix`
  - Owns reusable Mayastor host prerequisites: LVM initrd support, `nvme_tcp`, hugepages, XFS support, optional NVMe multipath, and a gated k3s node-label flag.
- Modify: `modules/nixos/opt/default.nix`
  - Imports the new Mayastor optional module.
- Modify: `hosts/dauwalter/default.nix`
  - Enables Mayastor host prerequisites.
- Modify: `hosts/fordyce/default.nix`
  - Enables Mayastor host prerequisites.
- Modify: `hosts/kipsang/default.nix`
  - Enables Mayastor host prerequisites.
- Modify: `hosts/selassie/default.nix`
  - Enables Mayastor host prerequisites.
- Modify: `hosts/walmsley/default.nix`
  - Enables Mayastor host prerequisites.
- Modify: `hosts/fordyce/disko.nix`
  - Converts NVMe root disk to GPT + LVM PV + root LV + raw Mayastor LV.
- Modify: `hosts/dauwalter/disko.nix`
  - Converts NVMe root disk to GPT + LVM PV + root LV + raw Mayastor LV.
- Modify: `hosts/kipsang/disko.nix`
  - Converts NVMe root disk to GPT + LVM PV + root LV + raw Mayastor LV while preserving SATA `/srv/data` disk.
- Modify: `hosts/walmsley/disko.nix`
  - Converts NVMe root disk to GPT + LVM PV + root LV + raw Mayastor LV while preserving SATA `/srv/data` disk.
- Modify: `hosts/selassie/disko.nix`
  - Converts NVMe root disk to GPT + LVM PV + root LV + raw Mayastor LV while preserving SATA `/srv/data` disk.

---

### Task 1: Add shared Mayastor host prerequisites module

**Files:**
- Create: `modules/nixos/opt/mayastor/default.nix`
- Modify: `modules/nixos/opt/default.nix`

- [ ] **Step 1: Create the Mayastor optional module**

Create `modules/nixos/opt/mayastor/default.nix` with this content:

```nix
{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab.storage.mayastor;
in
{
  options.homelab.storage.mayastor = {
    enable = lib.mkEnableOption "Mayastor host prerequisites";

    enableMultipath = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable NVMe native multipath for Mayastor NVMe-oF paths.";
    };

    hugepages2MiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1024;
      description = "Number of 2 MiB hugepages reserved for Mayastor io-engine.";
    };

    nodeLabel.enable = lib.mkEnableOption "the k3s Mayastor io-engine node label";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.initrd.services.lvm.enable = true;
      boot.kernelModules = [ "nvme_tcp" ];
      boot.kernelParams =
        [
          "default_hugepagesz=2M"
          "hugepagesz=2M"
          "hugepages=${toString cfg.hugepages2MiB}"
        ]
        ++ lib.optionals cfg.enableMultipath [
          "nvme_core.multipath=Y"
        ];
      boot.supportedFilesystems = [ "xfs" ];
    }

    (lib.mkIf cfg.nodeLabel.enable {
      services.k3s.extraFlags = lib.mkAfter " --node-label=openebs.io/engine=mayastor";
    })
  ]);
}
```

- [ ] **Step 2: Import the module from `modules/nixos/opt/default.nix`**

Replace the file with this sorted import list:

```nix
{
  imports = [
    ./desktop
    ./fonts
    ./k3s-reset
    ./mayastor
    ./options.nix
    ./vpn
  ];
}
```

- [ ] **Step 3: Format the Nix files**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt modules/nixos/opt/default.nix modules/nixos/opt/mayastor/default.nix
```

Expected: command exits 0 and either prints formatted file names or no output.

- [ ] **Step 4: Verify the module evaluates**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix eval .#nixosConfigurations.fordyce.options.homelab.storage.mayastor.enable.type
```

Expected: output contains `boolean`.

- [ ] **Step 5: Commit the module**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add modules/nixos/opt/default.nix modules/nixos/opt/mayastor/default.nix
git commit -m "feat(nixos): add Mayastor host prerequisites"
```

---

### Task 2: Enable Mayastor prerequisites on the five cluster hosts

**Files:**
- Modify: `hosts/dauwalter/default.nix`
- Modify: `hosts/fordyce/default.nix`
- Modify: `hosts/kipsang/default.nix`
- Modify: `hosts/selassie/default.nix`
- Modify: `hosts/walmsley/default.nix`

- [ ] **Step 1: Add the shared Mayastor prerequisite config to each host**

In each of the five host `default.nix` files, add this top-level attribute inside the module body. Place it after `swapDevices` or before `services.openiscsi` so host infrastructure settings stay grouped together:

```nix
  homelab.storage.mayastor = {
    enable = true;
    enableMultipath = true;
    hugepages2MiB = 1024;
  };
```

Do not set `homelab.storage.mayastor.nodeLabel.enable` in this task. Node labels are enabled only after the corresponding host has been rebuilt and its raw LV has been verified.

- [ ] **Step 2: Format the host files**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt \
  hosts/dauwalter/default.nix \
  hosts/fordyce/default.nix \
  hosts/kipsang/default.nix \
  hosts/selassie/default.nix \
  hosts/walmsley/default.nix
```

Expected: command exits 0.

- [ ] **Step 3: Verify one host exposes the expected kernel settings**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix eval .#nixosConfigurations.fordyce.config.boot.kernelModules
nix eval .#nixosConfigurations.fordyce.config.boot.kernelParams
```

Expected: the first output includes `nvme_tcp`; the second output includes `hugepages=1024` and `nvme_core.multipath=Y`.

- [ ] **Step 4: Build all five host toplevels**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
for host in dauwalter fordyce kipsang selassie walmsley; do
  nix build ".#nixosConfigurations.${host}.config.system.build.toplevel"
done
```

Expected: all five builds exit 0.

- [ ] **Step 5: Commit the host enablement**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add \
  hosts/dauwalter/default.nix \
  hosts/fordyce/default.nix \
  hosts/kipsang/default.nix \
  hosts/selassie/default.nix \
  hosts/walmsley/default.nix
git commit -m "feat(nixos): enable Mayastor host prerequisites"
```

---

### Task 3: Convert `fordyce` NVMe disk to LVM layout

**Files:**
- Modify: `hosts/fordyce/disko.nix`

- [ ] **Step 1: Replace `hosts/fordyce/disko.nix`**

Write this exact content:

```nix
{ lib, ... }:
{
  disko.devices = {
    disk.nvme = {
      device = lib.mkDefault "/dev/disk/by-id/nvme-eui.2c3ebffff000277a";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          lvm = {
            name = "lvm";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "vg-nvme";
            };
          };
        };
      };
    };

    lvm_vg."vg-nvme" = {
      type = "lvm_vg";
      lvs = {
        "mayastor-appstate" = {
          size = "100G";
        };
        root = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
```

- [ ] **Step 2: Format the file**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt hosts/fordyce/disko.nix
```

Expected: command exits 0.

- [ ] **Step 3: Build the `fordyce` toplevel**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix build .#nixosConfigurations.fordyce.config.system.build.toplevel
```

Expected: build exits 0.

- [ ] **Step 4: Commit the `fordyce` disk layout**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add hosts/fordyce/disko.nix
git commit -m "feat(nixos): add fordyce Mayastor NVMe LV"
```

- [ ] **Step 5: Confirm and drain `fordyce` during a maintenance window**

Before draining, confirm that console or remote recovery access is available and that `.kubeconfig` is present at the worktree root.

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
test -f .kubeconfig
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes fordyce -o wide
KUBECONFIG="$PWD/.kubeconfig" kubectl get pods -A --field-selector spec.nodeName=fordyce
read -r -p "Type 'drain fordyce' to drain fordyce: " confirm
test "$confirm" = "drain fordyce"
KUBECONFIG="$PWD/.kubeconfig" kubectl drain fordyce --ignore-daemonsets --delete-emptydir-data --timeout=20m
```

Expected: `kubectl drain` exits 0 and `fordyce` is cordoned with ordinary workloads evicted. If drain fails because of a PodDisruptionBudget or unmanaged pod, stop and resolve that workload before reinstalling.

- [ ] **Step 6: Confirm and destructively reinstall `fordyce`**

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
read -r -p "Type 'deploy fordyce' to run scripts/deploy-nixos.sh fordyce 192.168.1.102: " confirm
test "$confirm" = "deploy fordyce"
scripts/deploy-nixos.sh fordyce 192.168.1.102
```

Expected: `nixos-anywhere` completes successfully and `fordyce` reboots into the new NixOS generation.

- [ ] **Step 7: Verify and uncordon `fordyce` after reinstall**

Run checks:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG="$PWD/.kubeconfig" kubectl wait --for=condition=Ready node/fordyce --timeout=10m
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes fordyce -o wide
ssh root@192.168.1.102 'lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate && findmnt /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate || true'
ssh root@192.168.1.102 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
KUBECONFIG="$PWD/.kubeconfig" kubectl uncordon fordyce
```

Expected:

- `kubectl wait` and `kubectl get nodes` show `fordyce` as `Ready`.
- `lsblk` shows the `mayastor-appstate` LV with no filesystem.
- `findmnt` prints nothing for the LV and exits through `|| true`.
- `readlink` resolves to a `/dev/dm-*` path.
- `kubectl uncordon` marks the node schedulable again.

---

### Task 4: Convert `dauwalter` NVMe disk to LVM layout

**Files:**
- Modify: `hosts/dauwalter/disko.nix`

- [ ] **Step 1: Replace `hosts/dauwalter/disko.nix`**

Write this exact content:

```nix
{ lib, ... }:
{
  disko.devices = {
    disk.disk1 = {
      device = lib.mkDefault "/dev/disk/by-id/nvme-eui.335a47304d2004040025385800000001";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          lvm = {
            name = "lvm";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "vg-nvme";
            };
          };
        };
      };
    };

    lvm_vg."vg-nvme" = {
      type = "lvm_vg";
      lvs = {
        "mayastor-appstate" = {
          size = "100G";
        };
        root = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
```

- [ ] **Step 2: Format and build `dauwalter`**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt hosts/dauwalter/disko.nix
nix build .#nixosConfigurations.dauwalter.config.system.build.toplevel
```

Expected: both commands exit 0.

- [ ] **Step 3: Commit the `dauwalter` disk layout**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add hosts/dauwalter/disko.nix
git commit -m "feat(nixos): add dauwalter Mayastor NVMe LV"
```

- [ ] **Step 4: Preflight, confirm, and drain `dauwalter` only after `fordyce` is healthy**

`dauwalter` is the current k3s `clusterInit` node and the server address used by the other host configs. Drain it only after `fordyce` is Ready and the cluster has healthy etcd/control-plane members.

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
test -f .kubeconfig
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes -o wide
KUBECONFIG="$PWD/.kubeconfig" kubectl get pods -A --field-selector spec.nodeName=dauwalter
read -r -p "Type 'drain dauwalter' to drain dauwalter: " confirm
test "$confirm" = "drain dauwalter"
KUBECONFIG="$PWD/.kubeconfig" kubectl drain dauwalter --ignore-daemonsets --delete-emptydir-data --timeout=20m
```

Expected: `kubectl drain` exits 0 and `dauwalter` is cordoned with ordinary workloads evicted. If drain fails, stop and resolve the blocking workload before reinstalling.

- [ ] **Step 5: Confirm and destructively reinstall `dauwalter`**

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
read -r -p "Type 'deploy dauwalter' to run scripts/deploy-nixos.sh dauwalter 192.168.1.100: " confirm
test "$confirm" = "deploy dauwalter"
scripts/deploy-nixos.sh dauwalter 192.168.1.100
```

Expected: `nixos-anywhere` completes successfully and `dauwalter` returns as Ready.

- [ ] **Step 6: Verify and uncordon `dauwalter` after reinstall**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG="$PWD/.kubeconfig" kubectl wait --for=condition=Ready node/dauwalter --timeout=10m
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes dauwalter -o wide
ssh root@192.168.1.100 'lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate && findmnt /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate || true'
ssh root@192.168.1.100 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
KUBECONFIG="$PWD/.kubeconfig" kubectl uncordon dauwalter
```

Expected: the node is Ready and schedulable, and the Mayastor LV is raw, unmounted, and addressable by stable by-id path.

---

### Task 5: Convert `kipsang` NVMe disk while preserving SATA `/srv/data`

**Files:**
- Modify: `hosts/kipsang/disko.nix`

- [ ] **Step 1: Replace `hosts/kipsang/disko.nix`**

Write this exact content:

```nix
{ lib, ... }:
{
  disko.devices = {
    # System NVMe (by-id for stability)
    disk.nvme = {
      device = lib.mkDefault "/dev/disk/by-id/nvme-eui.2c3ebffff000290a";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          lvm = {
            name = "lvm";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "vg-nvme";
            };
          };
        };
      };
    };

    # 16TB SATA data disk
    disk.data = {
      device = lib.mkDefault "/dev/disk/by-id/wwn-0x5000c500c961abb2";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          data = {
            name = "data";
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/srv/data";
              mountOptions = [
                "noatime"
              ];
            };
          };
        };
      };
    };

    lvm_vg."vg-nvme" = {
      type = "lvm_vg";
      lvs = {
        "mayastor-appstate" = {
          size = "100G";
        };
        root = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
```

- [ ] **Step 2: Format and build `kipsang`**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt hosts/kipsang/disko.nix
nix build .#nixosConfigurations.kipsang.config.system.build.toplevel
```

Expected: both commands exit 0.

- [ ] **Step 3: Commit the `kipsang` disk layout**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add hosts/kipsang/disko.nix
git commit -m "feat(nixos): add kipsang Mayastor NVMe LV"
```

- [ ] **Step 4: Confirm and drain `kipsang` during a maintenance window**

Confirm out-of-band that `/srv/data` contents are backed up or acceptable to recreate. This disko file still declares the SATA disk, so `nixos-anywhere` can recreate it.

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
test -f .kubeconfig
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes kipsang -o wide
KUBECONFIG="$PWD/.kubeconfig" kubectl get pods -A --field-selector spec.nodeName=kipsang
read -r -p "Type 'drain kipsang' to drain kipsang: " confirm
test "$confirm" = "drain kipsang"
KUBECONFIG="$PWD/.kubeconfig" kubectl drain kipsang --ignore-daemonsets --delete-emptydir-data --timeout=20m
```

Expected: `kubectl drain` exits 0 and `kipsang` is cordoned with ordinary workloads evicted. If drain fails, stop and resolve the blocking workload before reinstalling.

- [ ] **Step 5: Confirm and destructively reinstall `kipsang`**

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
read -r -p "Type 'deploy kipsang' to run scripts/deploy-nixos.sh kipsang 192.168.1.101: " confirm
test "$confirm" = "deploy kipsang"
scripts/deploy-nixos.sh kipsang 192.168.1.101
```

Expected: `nixos-anywhere` completes successfully and `kipsang` returns as Ready.

- [ ] **Step 6: Verify and uncordon `kipsang` after reinstall**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG="$PWD/.kubeconfig" kubectl wait --for=condition=Ready node/kipsang --timeout=10m
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes kipsang -o wide
ssh root@192.168.1.101 'findmnt /srv/data && lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate && findmnt /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate || true'
ssh root@192.168.1.101 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
KUBECONFIG="$PWD/.kubeconfig" kubectl uncordon kipsang
```

Expected: `/srv/data` is mounted, the Mayastor LV is raw and unmounted, and the node is Ready and schedulable.

---

### Task 6: Convert `walmsley` NVMe disk while preserving SATA `/srv/data`

**Files:**
- Modify: `hosts/walmsley/disko.nix`

- [ ] **Step 1: Replace `hosts/walmsley/disko.nix`**

Write this exact content:

```nix
{ lib, ... }:
{
  disko.devices = {
    disk.nvme = {
      device = lib.mkDefault "/dev/disk/by-id/nvme-eui.2c3ebffff0002924";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          lvm = {
            name = "lvm";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "vg-nvme";
            };
          };
        };
      };
    };

    disk.data = {
      device = lib.mkDefault "/dev/disk/by-id/wwn-0x5000c500c96ed8a1";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          data = {
            name = "data";
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/srv/data";
              mountOptions = [
                "noatime"
              ];
            };
          };
        };
      };
    };

    lvm_vg."vg-nvme" = {
      type = "lvm_vg";
      lvs = {
        "mayastor-appstate" = {
          size = "100G";
        };
        root = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
```

- [ ] **Step 2: Format and build `walmsley`**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt hosts/walmsley/disko.nix
nix build .#nixosConfigurations.walmsley.config.system.build.toplevel
```

Expected: both commands exit 0.

- [ ] **Step 3: Commit the `walmsley` disk layout**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add hosts/walmsley/disko.nix
git commit -m "feat(nixos): add walmsley Mayastor NVMe LV"
```

- [ ] **Step 4: Confirm and drain `walmsley` during a maintenance window**

Confirm out-of-band that `/srv/data` contents are backed up or acceptable to recreate.

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
test -f .kubeconfig
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes walmsley -o wide
KUBECONFIG="$PWD/.kubeconfig" kubectl get pods -A --field-selector spec.nodeName=walmsley
read -r -p "Type 'drain walmsley' to drain walmsley: " confirm
test "$confirm" = "drain walmsley"
KUBECONFIG="$PWD/.kubeconfig" kubectl drain walmsley --ignore-daemonsets --delete-emptydir-data --timeout=20m
```

Expected: `kubectl drain` exits 0 and `walmsley` is cordoned with ordinary workloads evicted. If drain fails, stop and resolve the blocking workload before reinstalling.

- [ ] **Step 5: Confirm and destructively reinstall `walmsley`**

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
read -r -p "Type 'deploy walmsley' to run scripts/deploy-nixos.sh walmsley 192.168.1.103: " confirm
test "$confirm" = "deploy walmsley"
scripts/deploy-nixos.sh walmsley 192.168.1.103
```

Expected: `nixos-anywhere` completes successfully and `walmsley` returns as Ready.

- [ ] **Step 6: Verify and uncordon `walmsley` after reinstall**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG="$PWD/.kubeconfig" kubectl wait --for=condition=Ready node/walmsley --timeout=10m
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes walmsley -o wide
ssh root@192.168.1.103 'findmnt /srv/data && lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate && findmnt /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate || true'
ssh root@192.168.1.103 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
KUBECONFIG="$PWD/.kubeconfig" kubectl uncordon walmsley
```

Expected: `/srv/data` is mounted, the Mayastor LV is raw and unmounted, and the node is Ready and schedulable.

---

### Task 7: Convert `selassie` NVMe disk while preserving SATA `/srv/data`

**Files:**
- Modify: `hosts/selassie/disko.nix`

- [ ] **Step 1: Replace `hosts/selassie/disko.nix`**

Write this exact content:

```nix
{ lib, ... }:
{
  disko.devices = {
    disk.nvme = {
      device = lib.mkDefault "/dev/disk/by-id/nvme-eui.0025388581b2f42d";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          lvm = {
            name = "lvm";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "vg-nvme";
            };
          };
        };
      };
    };

    disk.data = {
      device = lib.mkDefault "/dev/disk/by-id/ata-ST16000NM001G-2KK103_ZL2FS4RR";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          data = {
            name = "data";
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/srv/data";
              mountOptions = [
                "noatime"
              ];
            };
          };
        };
      };
    };

    lvm_vg."vg-nvme" = {
      type = "lvm_vg";
      lvs = {
        "mayastor-appstate" = {
          size = "100G";
        };
        root = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
```

- [ ] **Step 2: Format and build `selassie`**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt hosts/selassie/disko.nix
nix build .#nixosConfigurations.selassie.config.system.build.toplevel
```

Expected: both commands exit 0.

- [ ] **Step 3: Commit the `selassie` disk layout**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add hosts/selassie/disko.nix
git commit -m "feat(nixos): add selassie Mayastor NVMe LV"
```

- [ ] **Step 4: Confirm and drain `selassie` during a maintenance window**

Confirm out-of-band that `/srv/data` contents are backed up or acceptable to recreate.

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
test -f .kubeconfig
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes selassie -o wide
KUBECONFIG="$PWD/.kubeconfig" kubectl get pods -A --field-selector spec.nodeName=selassie
read -r -p "Type 'drain selassie' to drain selassie: " confirm
test "$confirm" = "drain selassie"
KUBECONFIG="$PWD/.kubeconfig" kubectl drain selassie --ignore-daemonsets --delete-emptydir-data --timeout=20m
```

Expected: `kubectl drain` exits 0 and `selassie` is cordoned with ordinary workloads evicted. If drain fails, stop and resolve the blocking workload before reinstalling.

- [ ] **Step 5: Confirm and destructively reinstall `selassie`**

Run from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
read -r -p "Type 'deploy selassie' to run scripts/deploy-nixos.sh selassie 192.168.1.104: " confirm
test "$confirm" = "deploy selassie"
scripts/deploy-nixos.sh selassie 192.168.1.104
```

Expected: `nixos-anywhere` completes successfully and `selassie` returns as Ready.

- [ ] **Step 6: Verify and uncordon `selassie` after reinstall**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG="$PWD/.kubeconfig" kubectl wait --for=condition=Ready node/selassie --timeout=10m
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes selassie -o wide
ssh root@192.168.1.104 'findmnt /srv/data && lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate && findmnt /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate || true'
ssh root@192.168.1.104 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
KUBECONFIG="$PWD/.kubeconfig" kubectl uncordon selassie
```

Expected: `/srv/data` is mounted, the Mayastor LV is raw and unmounted, and the node is Ready and schedulable.

---

### Task 8: Enable Mayastor node label only after each node is verified

**Files:**
- Modify as each node becomes ready: `hosts/<node>/default.nix`

- [ ] **Step 1: Enable the label for a verified node**

After a node has been rebuilt and the raw LV has been verified, add this line inside that host's existing `homelab.storage.mayastor` block:

```nix
    nodeLabel.enable = true;
```

For example, after `fordyce` is verified, the block in `hosts/fordyce/default.nix` becomes:

```nix
  homelab.storage.mayastor = {
    enable = true;
    enableMultipath = true;
    hugepages2MiB = 1024;
    nodeLabel.enable = true;
  };
```

- [ ] **Step 2: Format and build the labeled node**

For `fordyce`, run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt hosts/fordyce/default.nix
nix build .#nixosConfigurations.fordyce.config.system.build.toplevel
```

Expected: both commands exit 0.

- [ ] **Step 3: Deploy the label through NixOS for that node**

For `fordyce`, run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nixos-rebuild build --flake .#fordyce
```

Expected: build exits 0. Then deploy through the repository's normal NixOS deployment path for an already-installed node. Do not use `kubectl label` from the agent.

- [ ] **Step 4: Verify the label after the node's k3s service restarts**

Run read-only verification from the worktree:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG="$PWD/.kubeconfig" kubectl get nodes fordyce --show-labels | grep 'openebs.io/engine=mayastor'
```

Expected: the line for `fordyce` includes `openebs.io/engine=mayastor`.

- [ ] **Step 5: Commit the label change for that node**

For `fordyce`, run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add hosts/fordyce/default.nix
git commit -m "feat(nixos): label fordyce for Mayastor"
```

Repeat the same small edit, build, deploy, verify, and commit sequence for `dauwalter`, `kipsang`, `walmsley`, and `selassie` only after each one has a verified raw Mayastor LV.

---

### Task 9: Run final Nix verification

**Files:**
- No file changes.

- [ ] **Step 1: Run formatter across the repo**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt
```

Expected: command exits 0.

- [ ] **Step 2: Build all affected NixOS hosts**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
for host in dauwalter fordyce kipsang selassie walmsley; do
  nix build ".#nixosConfigurations.${host}.config.system.build.toplevel"
done
```

Expected: all five builds exit 0.

- [ ] **Step 3: Run full flake check**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix flake check
```

Expected: `all checks passed!`.

- [ ] **Step 4: Confirm no accidental uncommitted changes remain**

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git status --short
```

Expected: no output.

---

### Task 10: GitOps handoff for OpenEBS Mayastor manifests

**Files:**
- No file changes in `~/nixdots`.

- [ ] **Step 1: Record the verified by-id device path for each rebuilt node**

For each rebuilt node, run the corresponding read-only command and save the output in the GitOps issue or follow-up plan:

```bash
ssh root@192.168.1.102 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
ssh root@192.168.1.100 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
ssh root@192.168.1.101 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
ssh root@192.168.1.103 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
ssh root@192.168.1.104 'readlink -f /dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate'
```

Expected: each command resolves to a `/dev/dm-*` path. The DiskPool manifests should still use the stable `/dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate` path, not the resolved `/dev/dm-*` path.

- [ ] **Step 2: Start a separate GitOps plan in the repository that owns ArgoCD manifests**

The GitOps plan must create:

```yaml
apiVersion: openebs.io/v1beta3
kind: DiskPool
metadata:
  name: pool-on-fordyce
  namespace: openebs
spec:
  node: fordyce
  disks:
    - aio:///dev/disk/by-id/dm-name-vg--nvme-mayastor--appstate
```

Use one DiskPool per verified node. Create the pilot StorageClass only after at least three DiskPools are present.

- [ ] **Step 3: Keep `repl: "3"` gated on three verified nodes**

The first pilot StorageClass in the GitOps repo should use `repl: "3"` only after three nodes have verified DiskPools. Before that, use non-critical `repl: "2"` testing or do not provision Mayastor PVCs.

- [ ] **Step 4: Run Mayastor failure validation before app migration**

Do not migrate a real app-state PVC until the GitOps follow-up proves:

```text
- Disposable PVC provisions successfully.
- A repl=3 PVC survives a non-primary node reboot.
- A workload using the PVC can move after the original node is rebooted.
- Metrics or alerts expose DiskPool capacity, degraded replicas, and unavailable volumes.
```
