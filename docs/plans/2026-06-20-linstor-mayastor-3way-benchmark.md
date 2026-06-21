# LINSTOR/Piraeus vs Mayastor 3-Way Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a real 3-node, 3-replica A/B benchmark of OpenEBS Replicated PV Mayastor and LINSTOR/Piraeus on disposable NVMe/LVM-backed homelab storage.

**Architecture:** Prepare the same three NixOS/k3s nodes with disposable NVMe-backed LVM capacity for both backends, then deploy each Kubernetes storage backend through ArgoCD one at a time. Benchmark each backend with the same GitOps-managed fio Job and compare fio latency/throughput plus recovery and operational complexity.

**Tech Stack:** NixOS, disko, k3s, ArgoCD, Kustomize, Helm charts, OpenEBS Replicated PV Mayastor, Piraeus Datastore/LINSTOR/DRBD, LVM thin pools, fio, jq, Python 3.

---

## Important Constraints

- NixOS host work happens in `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm` on branch `feature/mayastor-nvme-lvm`.
- GitOps Kubernetes work happens in a new worktree under `/home/roche/homelab-k8s/.worktrees/storage-benchmark` on branch `feature/storage-benchmark`.
- Kubernetes application/storage resources must be delivered through the GitOps repository and ArgoCD.
- Do not run direct-write commands such as `kubectl apply`, `kubectl patch`, `kubectl delete`, or `helm upgrade` against homelab.
- Read-only cluster inspection is allowed: `kubectl get`, `kubectl describe`, `kubectl logs`, `kubectl exec` for read-only backend CLIs.
- Node maintenance commands such as drain, uncordon, and reboot require typed operator confirmation at the moment they run.
- Longhorn-backed production PVCs remain untouched.
- Benchmark PVCs are disposable.

## File Structure

### NixOS host repository: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm`

- Modify `modules/nixos/opt/default.nix` to import the LINSTOR host prerequisite module.
- Create `modules/nixos/opt/linstor/default.nix` for DRBD/LVM host prerequisites and the benchmark node label.
- Modify `hosts/dauwalter/default.nix`, `hosts/fordyce/default.nix`, and `hosts/selassie/default.nix` to enable Mayastor and LINSTOR benchmark prerequisites.
- Modify `hosts/dauwalter/disko.nix`, `hosts/fordyce/disko.nix`, and `hosts/selassie/disko.nix` to create equal disposable Mayastor and LINSTOR benchmark storage.
- Modify `hosts/kipsang/default.nix` and `hosts/walmsley/default.nix` only to resolve the existing unused `lib` argument review finding.

### GitOps repository: `/home/roche/homelab-k8s/.worktrees/storage-benchmark`

- Create `argocd/base/openebs-mayastor/` for the OpenEBS Helm Application.
- Create `argocd/base/mayastor-benchmark/` for benchmark DiskPools, StorageClass, PVC, and fio Job.
- Create `argocd/homelab/mayastor-benchmark/` for Mayastor benchmark manifests.
- Create `argocd/base/piraeus-operator/` for the Piraeus operator Helm Application.
- Create `argocd/base/piraeus-benchmark/` for LINSTOR/Piraeus cluster, storage pool, StorageClass, PVC, and fio Job.
- Create `argocd/homelab/piraeus-benchmark/` for LINSTOR/Piraeus benchmark manifests.
- Modify `argocd/homelab/apps/kustomization.yaml` only during the active benchmark phase to wire one backend at a time.
- Create `scripts/summarize-storage-benchmark.py` to turn fio `RESULT,...` log lines into a Markdown comparison table.
- Store collected logs and summaries under `docs/storage-benchmark/` in the GitOps worktree.

---

### Task 1: Prepare the GitOps worktree and baseline checks

**Files:**
- No file changes in this task.

- [ ] **Step 1: Verify the NixOS benchmark worktree**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git branch --show-current
git status --short
```

Expected output:

```text
feature/mayastor-nvme-lvm
```

Expected: `git status --short` prints no files.

- [ ] **Step 2: Create an isolated GitOps worktree**

Run:

```bash
cd /home/roche/homelab-k8s
mkdir -p .worktrees
git check-ignore -q .worktrees
git worktree add .worktrees/storage-benchmark -b feature/storage-benchmark
```

Expected: `git worktree add` exits 0 and creates `/home/roche/homelab-k8s/.worktrees/storage-benchmark`.

- [ ] **Step 3: Verify the GitOps worktree baseline**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
git branch --show-current
git status --short
kubectl kustomize argocd/homelab/apps >/tmp/homelab-apps-render.yaml
python3 - <<'PY'
from pathlib import Path
rendered = Path('/tmp/homelab-apps-render.yaml')
assert rendered.exists()
text = rendered.read_text()
assert 'kind: Application' in text
print('rendered Applications:', text.count('kind: Application'))
PY
```

Expected output includes:

```text
feature/storage-benchmark
rendered Applications:
```

Expected: `git status --short` prints no files.

---

### Task 2: Add LINSTOR host prerequisites and resolve existing Nix review finding

**Files:**
- Create: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/modules/nixos/opt/linstor/default.nix`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/modules/nixos/opt/default.nix`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/dauwalter/default.nix`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/fordyce/default.nix`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/kipsang/default.nix`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/selassie/default.nix`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/walmsley/default.nix`

- [ ] **Step 1: Create the LINSTOR host module**

Create `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/modules/nixos/opt/linstor/default.nix` with this content:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.storage.linstor;
in
{
  options.homelab.storage.linstor = {
    enable = lib.mkEnableOption "LINSTOR/Piraeus host prerequisites";

    nodeLabel.enable = lib.mkEnableOption "the k3s LINSTOR benchmark node label";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        boot.extraModulePackages = [ config.boot.kernelPackages.drbd ];
        boot.initrd.services.lvm.enable = true;
        boot.kernelModules = [ "drbd" ];

        environment.systemPackages = [
          pkgs.drbd
          pkgs.lvm2
        ];
      }

      (lib.mkIf cfg.nodeLabel.enable {
        services.k3s.extraFlags = lib.mkAfter [
          "--node-label=storage.compaan.io/linstor-benchmark=true"
        ];
      })
    ]
  );
}
```

- [ ] **Step 2: Import the LINSTOR module**

Edit `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/modules/nixos/opt/default.nix` so it is exactly:

```nix
{
  imports = [
    ./desktop
    ./fonts
    ./k3s-reset
    ./linstor
    ./mayastor
    ./options.nix
    ./vpn
  ];
}
```

- [ ] **Step 3: Resolve the existing unused `lib` argument finding**

Run this targeted edit:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
python3 - <<'PY'
from pathlib import Path
for rel in [
    'hosts/dauwalter/default.nix',
    'hosts/fordyce/default.nix',
    'hosts/kipsang/default.nix',
    'hosts/selassie/default.nix',
    'hosts/walmsley/default.nix',
]:
    path = Path(rel)
    text = path.read_text()
    old = '{\n  config,\n  lib,\n  inputs,\n  ...\n}:'
    new = '{\n  config,\n  inputs,\n  ...\n}:'
    if old not in text:
        raise SystemExit(f'{rel}: expected argument block not found')
    path.write_text(text.replace(old, new, 1))
PY
```

Expected: the command exits 0.

- [ ] **Step 4: Enable benchmark prerequisites on the selected nodes**

Insert this block in each selected host file just before `# homelab.k3s.reset.enable = true;`:

```nix
  homelab.storage = {
    linstor = {
      enable = true;
      nodeLabel.enable = true;
    };

    mayastor = {
      enable = true;
      enableMultipath = true;
      nodeLabel.enable = true;
    };
  };
```

Apply the insertion to these files:

```text
/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/dauwalter/default.nix
/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/fordyce/default.nix
/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/selassie/default.nix
```

Do not add the block to `kipsang` or `walmsley`.

- [ ] **Step 5: Format and evaluate affected host modules**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt modules/nixos/opt/default.nix modules/nixos/opt/linstor/default.nix hosts/dauwalter/default.nix hosts/fordyce/default.nix hosts/kipsang/default.nix hosts/selassie/default.nix hosts/walmsley/default.nix
nix eval --raw .#nixosConfigurations.dauwalter.config.boot.kernelPackages.drbd.name
nix eval --raw .#nixosConfigurations.dauwalter.pkgs.drbd.name
nix build .#nixosConfigurations.dauwalter.config.system.build.toplevel
nix build .#nixosConfigurations.fordyce.config.system.build.toplevel
nix build .#nixosConfigurations.selassie.config.system.build.toplevel
```

Expected:

- DRBD kernel module eval prints `drbd-9.2.16` or a newer compatible version.
- DRBD userspace eval prints `drbd-9.33.0` or a newer compatible version.
- All three `nix build` commands exit 0.

- [ ] **Step 6: Commit host prerequisite changes**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add modules/nixos/opt/default.nix modules/nixos/opt/linstor/default.nix hosts/dauwalter/default.nix hosts/fordyce/default.nix hosts/kipsang/default.nix hosts/selassie/default.nix hosts/walmsley/default.nix
git commit -m "feat(nixos): add LINSTOR benchmark prerequisites"
```

Expected: commit succeeds with signing and hooks intact.

---

### Task 3: Add disposable NVMe/LVM benchmark storage to selected hosts

**Files:**
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/dauwalter/disko.nix`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/fordyce/disko.nix`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/selassie/disko.nix`

- [ ] **Step 1: Replace `dauwalter` disk layout**

Write this exact content to `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/dauwalter/disko.nix`:

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
        "linstor-bench-thin" = {
          size = "30G";
          lvm_type = "thin-pool";
        };
        "mayastor-bench" = {
          size = "30G";
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

- [ ] **Step 2: Replace `fordyce` disk layout**

Write this exact content to `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/fordyce/disko.nix`:

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
        "linstor-bench-thin" = {
          size = "30G";
          lvm_type = "thin-pool";
        };
        "mayastor-bench" = {
          size = "30G";
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

- [ ] **Step 3: Replace `selassie` disk layout**

Write this exact content to `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/hosts/selassie/disko.nix`:

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
        "linstor-bench-thin" = {
          size = "30G";
          lvm_type = "thin-pool";
        };
        "mayastor-bench" = {
          size = "30G";
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

- [ ] **Step 4: Format and build all selected hosts**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
nix fmt hosts/dauwalter/disko.nix hosts/fordyce/disko.nix hosts/selassie/disko.nix
nix build .#nixosConfigurations.dauwalter.config.system.build.toplevel
nix build .#nixosConfigurations.fordyce.config.system.build.toplevel
nix build .#nixosConfigurations.selassie.config.system.build.toplevel
```

Expected: all commands exit 0.

- [ ] **Step 5: Commit the disposable benchmark disk layouts**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add hosts/dauwalter/disko.nix hosts/fordyce/disko.nix hosts/selassie/disko.nix
git commit -m "feat(nixos): add disposable storage benchmark LVs"
```

Expected: commit succeeds with signing and hooks intact.

---

### Task 4: Rebuild selected nodes one at a time and verify host storage

**Files:**
- No repository file changes in this task.

- [ ] **Step 1: Verify local kubeconfig availability**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
test -f .kubeconfig
KUBECONFIG=.kubeconfig kubectl get nodes dauwalter fordyce selassie -o wide
```

Expected: all three nodes are present before maintenance begins.

- [ ] **Step 2: Rebuild `dauwalter` with typed confirmation**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
read -r -p 'Type drain dauwalter: ' confirm
test "$confirm" = 'drain dauwalter'
KUBECONFIG=.kubeconfig kubectl drain dauwalter --ignore-daemonsets --delete-emptydir-data --timeout=20m
read -r -p 'Type deploy dauwalter: ' confirm
test "$confirm" = 'deploy dauwalter'
scripts/deploy-nixos.sh dauwalter
KUBECONFIG=.kubeconfig kubectl wait node/dauwalter --for=condition=Ready --timeout=20m
KUBECONFIG=.kubeconfig kubectl uncordon dauwalter
```

Expected: `dauwalter` returns to `Ready` before moving to the next node.

- [ ] **Step 3: Verify `dauwalter` benchmark storage**

Run:

```bash
ssh root@192.168.1.100 'set -e; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS; test -b /dev/disk/by-id/dm-name-vg--nvme-mayastor--bench; lvs -o lv_name,vg_name,lv_size,lv_attr vg-nvme; modprobe -n -v drbd; modprobe -n -v nvme_tcp; cat /proc/cmdline'
```

Expected:

- `/dev/disk/by-id/dm-name-vg--nvme-mayastor--bench` exists.
- `lvs` shows `linstor-bench-thin`, `mayastor-bench`, and `root`.
- `drbd` and `nvme_tcp` module probes resolve.
- Kernel command line includes `nvme_core.multipath=Y` and hugepage settings.

- [ ] **Step 4: Rebuild and verify `fordyce`**

Run the same command pattern as Steps 2 and 3, replacing:

```text
dauwalter -> fordyce
192.168.1.100 -> 192.168.1.102
```

Expected: `fordyce` returns to `Ready` and exposes the same benchmark LVs.

- [ ] **Step 5: Rebuild and verify `selassie`**

Run the same command pattern as Steps 2 and 3, replacing:

```text
dauwalter -> selassie
192.168.1.100 -> 192.168.1.104
```

Expected: `selassie` returns to `Ready`, `/srv/data` remains mounted, and the benchmark LVs exist.

- [ ] **Step 6: Verify all benchmark node labels**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG=.kubeconfig kubectl get nodes dauwalter fordyce selassie -L openebs.io/engine -L storage.compaan.io/linstor-benchmark
```

Expected:

- `openebs.io/engine` is `mayastor` on all three nodes.
- `storage.compaan.io/linstor-benchmark` is `true` on all three nodes.

---

### Task 5: Add shared benchmark result summarizer to the GitOps worktree

**Files:**
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/scripts/summarize-storage-benchmark.py`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/.gitkeep`

- [ ] **Step 1: Create the result directory marker**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
mkdir -p docs/storage-benchmark
touch docs/storage-benchmark/.gitkeep
```

- [ ] **Step 2: Create the summarizer script**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/scripts/summarize-storage-benchmark.py` with this content:

```python
#!/usr/bin/env python3
"""Summarize storage benchmark RESULT lines emitted by fio benchmark Jobs."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from statistics import mean

HEADER = [
    "backend",
    "profile",
    "passes",
    "read_iops_avg",
    "write_iops_avg",
    "read_mib_s_avg",
    "write_mib_s_avg",
    "read_p99_ms_avg",
    "write_p99_ms_avg",
    "read_p999_ms_avg",
    "write_p999_ms_avg",
    "errors_total",
]


def parse_result_lines(paths: list[Path]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    fields = [
        "marker",
        "backend",
        "profile",
        "pass",
        "read_iops",
        "write_iops",
        "read_mib_s",
        "write_mib_s",
        "read_mean_ms",
        "write_mean_ms",
        "read_p95_ms",
        "write_p95_ms",
        "read_p99_ms",
        "write_p99_ms",
        "read_p999_ms",
        "write_p999_ms",
        "errors",
    ]
    for path in paths:
        with path.open(newline="") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line.startswith("RESULT,"):
                    continue
                values = next(csv.reader([line]))
                if len(values) != len(fields):
                    raise ValueError(f"{path}: expected {len(fields)} fields, got {len(values)}: {line}")
                row = dict(zip(fields, values, strict=True))
                rows.append(row)
    return rows


def as_float(row: dict[str, str], key: str) -> float:
    return float(row[key])


def summarize(rows: list[dict[str, str]]) -> list[list[str]]:
    grouped: dict[tuple[str, str], list[dict[str, str]]] = {}
    for row in rows:
        grouped.setdefault((row["backend"], row["profile"]), []).append(row)

    summary: list[list[str]] = []
    for backend, profile in sorted(grouped):
        group = grouped[(backend, profile)]
        errors = sum(int(float(row["errors"])) for row in group)
        summary.append(
            [
                backend,
                profile,
                str(len(group)),
                f"{mean(as_float(row, 'read_iops') for row in group):.2f}",
                f"{mean(as_float(row, 'write_iops') for row in group):.2f}",
                f"{mean(as_float(row, 'read_mib_s') for row in group):.2f}",
                f"{mean(as_float(row, 'write_mib_s') for row in group):.2f}",
                f"{mean(as_float(row, 'read_p99_ms') for row in group):.3f}",
                f"{mean(as_float(row, 'write_p99_ms') for row in group):.3f}",
                f"{mean(as_float(row, 'read_p999_ms') for row in group):.3f}",
                f"{mean(as_float(row, 'write_p999_ms') for row in group):.3f}",
                str(errors),
            ]
        )
    return summary


def print_markdown(summary: list[list[str]]) -> None:
    print("| " + " | ".join(HEADER) + " |")
    print("| " + " | ".join(["---"] * len(HEADER)) + " |")
    for row in summary:
        print("| " + " | ".join(row) + " |")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args()
    rows = parse_result_lines(args.logs)
    if not rows:
        raise SystemExit("no RESULT lines found")
    print_markdown(summarize(rows))


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Verify the summarizer with sample data**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
python3 -m py_compile scripts/summarize-storage-benchmark.py
cat >/tmp/storage-benchmark-sample.log <<'EOF'
RESULT,mayastor,rand-write-4k,1,0,1000,0,4,0,1.5,0,2.0,0,3.0,0,4.0,0
RESULT,mayastor,rand-write-4k,2,0,2000,0,8,0,2.5,0,3.0,0,4.0,0,5.0,0
RESULT,piraeus,rand-write-4k,1,0,3000,0,12,0,3.5,0,4.0,0,5.0,0,6.0,0
EOF
scripts/summarize-storage-benchmark.py /tmp/storage-benchmark-sample.log
```

Expected output:

```text
| backend | profile | passes | read_iops_avg | write_iops_avg | read_mib_s_avg | write_mib_s_avg | read_p99_ms_avg | write_p99_ms_avg | read_p999_ms_avg | write_p999_ms_avg | errors_total |
```

- [ ] **Step 4: Commit the summarizer**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
git add scripts/summarize-storage-benchmark.py docs/storage-benchmark/.gitkeep
git commit -m "test(storage): add benchmark result summarizer"
```

Expected: commit succeeds with signing and hooks intact.

---

### Task 6: Add Mayastor GitOps benchmark manifests without wiring them live

**Files:**
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/openebs-mayastor/kustomization.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/openebs-mayastor/app.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/mayastor-benchmark/kustomization.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/mayastor-benchmark/app.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/kustomization.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/namespace.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/diskpools.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/storageclass.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/pvc.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/fio-job.yaml`

- [ ] **Step 1: Create the OpenEBS Helm Application**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/openebs-mayastor/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - app.yaml
```

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/openebs-mayastor/app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openebs-mayastor
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: '4'
spec:
  project: default
  source:
    chart: openebs
    repoURL: https://openebs.github.io/openebs
    targetRevision: 4.5.1
    helm:
      releaseName: openebs
      valuesObject:
        engines:
          local:
            lvm:
              enabled: false
            zfs:
              enabled: false
          replicated:
            mayastor:
              enabled: true
        mayastor:
          localpv-provisioner:
            enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: openebs
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Create the Mayastor benchmark Application**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/mayastor-benchmark/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - app.yaml
```

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/mayastor-benchmark/app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mayastor-benchmark
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: '5'
spec:
  project: default
  source:
    repoURL: git@github.com:rochecompaan/homelab-k8s.git
    targetRevision: main
    path: argocd/homelab/mayastor-benchmark
  destination:
    server: https://kubernetes.default.svc
    namespace: storage-benchmark
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Create the Mayastor benchmark Kustomization and namespace**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - diskpools.yaml
  - storageclass.yaml
  - pvc.yaml
  - fio-job.yaml
```

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: storage-benchmark
```

- [ ] **Step 4: Create Mayastor DiskPools**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/diskpools.yaml`:

```yaml
apiVersion: openebs.io/v1beta3
kind: DiskPool
metadata:
  name: mayastor-bench-dauwalter
  namespace: openebs
spec:
  node: dauwalter
  disks:
    - aio:///dev/disk/by-id/dm-name-vg--nvme-mayastor--bench
  maxExpansion: "1x"
---
apiVersion: openebs.io/v1beta3
kind: DiskPool
metadata:
  name: mayastor-bench-fordyce
  namespace: openebs
spec:
  node: fordyce
  disks:
    - aio:///dev/disk/by-id/dm-name-vg--nvme-mayastor--bench
  maxExpansion: "1x"
---
apiVersion: openebs.io/v1beta3
kind: DiskPool
metadata:
  name: mayastor-bench-selassie
  namespace: openebs
spec:
  node: selassie
  disks:
    - aio:///dev/disk/by-id/dm-name-vg--nvme-mayastor--bench
  maxExpansion: "1x"
```

- [ ] **Step 5: Create the Mayastor benchmark StorageClass and PVC**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/storageclass.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: mayastor-bench-3r
  labels:
    storage.compaan.io/benchmark: "true"
provisioner: io.openebs.csi-mayastor
allowVolumeExpansion: false
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  protocol: nvmf
  repl: "3"
```

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mayastor-fio-pvc
  namespace: storage-benchmark
spec:
  storageClassName: mayastor-bench-3r
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

- [ ] **Step 6: Create the Mayastor fio Job**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/mayastor-benchmark/fio-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: storage-bench-mayastor-run-001
  namespace: storage-benchmark
  labels:
    app.kubernetes.io/name: storage-benchmark
    storage.compaan.io/backend: mayastor
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: storage-benchmark
        storage.compaan.io/backend: mayastor
    spec:
      restartPolicy: Never
      nodeSelector:
        openebs.io/engine: mayastor
      containers:
        - name: fio
          image: nixery.dev/shell/fio/jq/coreutils
          imagePullPolicy: IfNotPresent
          env:
            - name: BACKEND
              value: mayastor
          command:
            - /bin/sh
            - -ec
          args:
            - |
              set -eu
              echo 'RESULT,backend,profile,pass,read_iops,write_iops,read_mib_s,write_mib_s,read_mean_ms,write_mean_ms,read_p95_ms,write_p95_ms,read_p99_ms,write_p99_ms,read_p999_ms,write_p999_ms,errors'
              out="/volume/results/${BACKEND}/$(date -u +%Y%m%dT%H%M%SZ)"
              mkdir -p "$out"
              datafile=/volume/fio-benchmark.dat
              fio --name=warmup --filename="$datafile" --rw=write --bs=1M --iodepth=16 --size=4G --ioengine=libaio --direct=1 --runtime=30 --time_based --group_reporting >/dev/null
              run_profile() {
                profile="$1"
                pass="$2"
                shift 2
                json="$out/${profile}-pass-${pass}.json"
                fio --name="$profile" --filename="$datafile" --size=4G --ioengine=libaio --direct=1 --time_based --runtime=60 --ramp_time=10 --group_reporting --output-format=json --output="$json" "$@"
                jq -r --arg backend "$BACKEND" --arg profile "$profile" --arg pass "$pass" '
                  .jobs[0] as $j |
                  [
                    "RESULT",
                    $backend,
                    $profile,
                    $pass,
                    ($j.read.iops // 0),
                    ($j.write.iops // 0),
                    (($j.read.bw_bytes // 0) / 1048576),
                    (($j.write.bw_bytes // 0) / 1048576),
                    (($j.read.clat_ns.mean // 0) / 1000000),
                    (($j.write.clat_ns.mean // 0) / 1000000),
                    (($j.read.clat_ns.percentile."95.000000" // 0) / 1000000),
                    (($j.write.clat_ns.percentile."95.000000" // 0) / 1000000),
                    (($j.read.clat_ns.percentile."99.000000" // 0) / 1000000),
                    (($j.write.clat_ns.percentile."99.000000" // 0) / 1000000),
                    (($j.read.clat_ns.percentile."99.900000" // 0) / 1000000),
                    (($j.write.clat_ns.percentile."99.900000" // 0) / 1000000),
                    ($j.error // 0)
                  ] | @csv
                ' "$json"
              }
              for pass in 1 2 3; do
                run_profile seq-write-1m "$pass" --rw=write --bs=1M --iodepth=16
                run_profile seq-read-1m "$pass" --rw=read --bs=1M --iodepth=16
                run_profile rand-write-4k "$pass" --rw=randwrite --bs=4k --iodepth=32
                run_profile rand-read-4k "$pass" --rw=randread --bs=4k --iodepth=32
                run_profile randrw-4k-70r30w "$pass" --rw=randrw --rwmixread=70 --bs=4k --iodepth=32
                run_profile sync-write-4k "$pass" --rw=write --bs=4k --iodepth=1 --fdatasync=1 --size=1G
              done
          volumeMounts:
            - name: fio-volume
              mountPath: /volume
      volumes:
        - name: fio-volume
          persistentVolumeClaim:
            claimName: mayastor-fio-pvc
```

- [ ] **Step 7: Render the Mayastor manifests**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
kubectl kustomize argocd/base/openebs-mayastor >/tmp/openebs-mayastor-app.yaml
kubectl kustomize argocd/base/mayastor-benchmark >/tmp/mayastor-benchmark-app.yaml
kubectl kustomize argocd/homelab/mayastor-benchmark >/tmp/mayastor-benchmark-render.yaml
python3 - <<'PY'
from pathlib import Path
rendered = Path('/tmp/mayastor-benchmark-render.yaml').read_text()
for needle in [
    'kind: DiskPool',
    'name: mayastor-bench-3r',
    'repl: "3"',
    'storage-bench-mayastor-run-001',
]:
    assert needle in rendered, needle
print('mayastor manifests render successfully')
PY
```

Expected output:

```text
mayastor manifests render successfully
```

- [ ] **Step 8: Commit dormant Mayastor manifests**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
git add argocd/base/openebs-mayastor argocd/base/mayastor-benchmark argocd/homelab/mayastor-benchmark
git commit -m "feat(storage): add Mayastor benchmark manifests"
```

Expected: commit succeeds. The apps are not live yet because `argocd/homelab/apps/kustomization.yaml` has not been changed.

---

### Task 7: Run the Mayastor benchmark through GitOps

**Files:**
- Modify: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/apps/kustomization.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/mayastor-run-001.log`

- [ ] **Step 1: Wire Mayastor apps into the bootstrap bundle**

Edit `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/apps/kustomization.yaml` and add these two resources after `../../base/longhorn-admission-hooks`:

```yaml
  - ../../base/openebs-mayastor
  - ../../base/mayastor-benchmark
```

Expected: no Piraeus resources are present in this file during the Mayastor run.

- [ ] **Step 2: Render and commit the Mayastor activation**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
kubectl kustomize argocd/homelab/apps >/tmp/homelab-apps-with-mayastor.yaml
python3 - <<'PY'
from pathlib import Path
text = Path('/tmp/homelab-apps-with-mayastor.yaml').read_text()
assert 'name: openebs-mayastor' in text
assert 'name: mayastor-benchmark' in text
assert 'name: piraeus-operator' not in text
print('mayastor activation render verified')
PY
git add argocd/homelab/apps/kustomization.yaml
git commit -m "feat(storage): enable Mayastor benchmark"
```

Expected output includes:

```text
mayastor activation render verified
```

- [ ] **Step 3: Push the GitOps branch after operator confirmation**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
read -r -p 'Type push Mayastor benchmark GitOps activation: ' confirm
test "$confirm" = 'push Mayastor benchmark GitOps activation'
git push origin HEAD
```

Expected: push succeeds. If ArgoCD follows `main` only, merge or fast-forward this branch to the watched branch using the repository's normal review path, then wait for ArgoCD to reconcile.

- [ ] **Step 4: Watch Mayastor converge with read-only commands**

Run from any workstation with cluster read access:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG=.kubeconfig kubectl -n argocd get applications openebs-mayastor mayastor-benchmark
KUBECONFIG=.kubeconfig kubectl -n openebs get pods -o wide
KUBECONFIG=.kubeconfig kubectl -n openebs get diskpools
KUBECONFIG=.kubeconfig kubectl -n storage-benchmark get pvc,pod,job -o wide
```

Expected:

- `openebs-mayastor` and `mayastor-benchmark` become Synced/Healthy in ArgoCD.
- Three DiskPools exist and are online.
- `mayastor-fio-pvc` binds.
- `storage-bench-mayastor-run-001` completes successfully.

- [ ] **Step 5: Collect Mayastor fio results**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n storage-benchmark logs job/storage-bench-mayastor-run-001 | tee docs/storage-benchmark/mayastor-run-001.log
scripts/summarize-storage-benchmark.py docs/storage-benchmark/mayastor-run-001.log | tee docs/storage-benchmark/mayastor-run-001-summary.md
git add docs/storage-benchmark/mayastor-run-001.log docs/storage-benchmark/mayastor-run-001-summary.md
git commit -m "perf(storage): record Mayastor benchmark results"
```

Expected:

- The log contains 18 `RESULT,mayastor,...` rows: 6 profiles x 3 passes.
- Summary generation exits 0.
- Commit succeeds.

- [ ] **Step 6: Record Mayastor health after the run**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
{
  echo '# Mayastor post-benchmark health'
  date -u
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n openebs get diskpools -o wide
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n openebs get pods -o wide
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n storage-benchmark get pvc,pv,pod,job -o wide
} | tee docs/storage-benchmark/mayastor-run-001-health.md
git add docs/storage-benchmark/mayastor-run-001-health.md
git commit -m "docs(storage): record Mayastor benchmark health"
```

Expected: health file shows three DiskPools and the completed fio Job.

---

### Task 8: Observe Mayastor degraded-node recovery

**Files:**
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/mayastor-recovery-observation.md`

- [ ] **Step 1: Confirm Mayastor starts healthy**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
{
  echo '# Mayastor recovery observation'
  date -u
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n openebs get diskpools -o wide
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n storage-benchmark get pvc,pod,job -o wide
} | tee docs/storage-benchmark/mayastor-recovery-observation.md
```

Expected: the benchmark PVC is bound and all three DiskPools are online before the outage.

- [ ] **Step 2: Reboot one Mayastor storage node with typed confirmation**

Use `selassie` as the recovery observation node.

Run:

```bash
read -r -p 'Type reboot selassie for Mayastor recovery observation: ' confirm
test "$confirm" = 'reboot selassie for Mayastor recovery observation'
ssh root@192.168.1.104 'systemctl reboot'
```

Expected: SSH disconnects because `selassie` reboots.

- [ ] **Step 3: Observe Mayastor during and after the reboot**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
for i in $(seq 1 30); do
  {
    echo
    echo "## observation ${i} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl get node selassie || true
    KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n openebs get diskpools -o wide || true
    KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n storage-benchmark get pvc,pod -o wide || true
  } | tee -a docs/storage-benchmark/mayastor-recovery-observation.md
  sleep 30
done
```

Expected: `selassie` returns to `Ready`; Mayastor eventually reports all three pools healthy again.

- [ ] **Step 4: Commit Mayastor recovery notes**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
git add docs/storage-benchmark/mayastor-recovery-observation.md
git commit -m "docs(storage): record Mayastor recovery observation"
```

Expected: commit succeeds.

---

### Task 9: Disable Mayastor benchmark resources through GitOps

**Files:**
- Modify: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/apps/kustomization.yaml`

- [ ] **Step 1: Remove Mayastor apps from the bootstrap bundle**

Edit `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/apps/kustomization.yaml` and remove these lines:

```yaml
  - ../../base/openebs-mayastor
  - ../../base/mayastor-benchmark
```

- [ ] **Step 2: Render and commit Mayastor disablement**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
kubectl kustomize argocd/homelab/apps >/tmp/homelab-apps-after-mayastor.yaml
python3 - <<'PY'
from pathlib import Path
text = Path('/tmp/homelab-apps-after-mayastor.yaml').read_text()
assert 'name: openebs-mayastor' not in text
assert 'name: mayastor-benchmark' not in text
print('mayastor disablement render verified')
PY
git add argocd/homelab/apps/kustomization.yaml
git commit -m "chore(storage): disable Mayastor benchmark"
```

Expected output includes:

```text
mayastor disablement render verified
```

- [ ] **Step 3: Push disablement after operator confirmation**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
read -r -p 'Type push Mayastor benchmark disablement: ' confirm
test "$confirm" = 'push Mayastor benchmark disablement'
git push origin HEAD
```

Expected: ArgoCD prunes Mayastor benchmark Applications after this change reaches the watched branch.

- [ ] **Step 4: Verify Mayastor resources are gone before Piraeus starts**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG=.kubeconfig kubectl -n argocd get applications openebs-mayastor mayastor-benchmark || true
KUBECONFIG=.kubeconfig kubectl -n storage-benchmark get pvc,pod,job || true
KUBECONFIG=.kubeconfig kubectl -n openebs get diskpools || true
```

Expected: benchmark resources are absent or visibly deleting before continuing.

---

### Task 10: Add Piraeus/LINSTOR GitOps benchmark manifests without wiring them live

**Files:**
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/piraeus-operator/kustomization.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/piraeus-operator/app.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/piraeus-benchmark/kustomization.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/piraeus-benchmark/app.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/kustomization.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/namespace.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/linstor-cluster.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/storageclass.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/pvc.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/fio-job.yaml`

- [ ] **Step 1: Create the Piraeus operator Application**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/piraeus-operator/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - app.yaml
```

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/piraeus-operator/app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: piraeus-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: '4'
spec:
  project: default
  source:
    chart: piraeus
    repoURL: ghcr.io/piraeusdatastore/piraeus-operator
    targetRevision: 2.10.7
    helm:
      releaseName: piraeus-operator
      valuesObject:
        installCRDs: true
  destination:
    server: https://kubernetes.default.svc
    namespace: piraeus-datastore
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Create the Piraeus benchmark Application**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/piraeus-benchmark/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - app.yaml
```

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/base/piraeus-benchmark/app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: piraeus-benchmark
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: '5'
spec:
  project: default
  source:
    repoURL: git@github.com:rochecompaan/homelab-k8s.git
    targetRevision: main
    path: argocd/homelab/piraeus-benchmark
  destination:
    server: https://kubernetes.default.svc
    namespace: piraeus-datastore
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Create the Piraeus benchmark Kustomization and namespace**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - linstor-cluster.yaml
  - storageclass.yaml
  - pvc.yaml
  - fio-job.yaml
```

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: storage-benchmark
```

- [ ] **Step 4: Create the Piraeus LinstorCluster and LVM thin storage pool**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/linstor-cluster.yaml`:

```yaml
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstorcluster
spec:
  nodeSelector:
    storage.compaan.io/linstor-benchmark: "true"
---
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: linstor-bench-storage
spec:
  nodeSelector:
    storage.compaan.io/linstor-benchmark: "true"
  storagePools:
    - name: linstor-bench
      lvmThinPool:
        volumeGroup: vg-nvme
        thinPool: linstor-bench-thin
```

- [ ] **Step 5: Create the Piraeus StorageClass and PVC**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/storageclass.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: piraeus-bench-3r
  labels:
    storage.compaan.io/benchmark: "true"
provisioner: linstor.csi.linbit.com
allowVolumeExpansion: false
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  linstor.csi.linbit.com/storagePool: linstor-bench
  linstor.csi.linbit.com/placementCount: "3"
```

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: piraeus-fio-pvc
  namespace: storage-benchmark
spec:
  storageClassName: piraeus-bench-3r
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

- [ ] **Step 6: Create the Piraeus fio Job**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/piraeus-benchmark/fio-job.yaml` by copying the Mayastor fio Job and changing these exact fields:

```yaml
metadata:
  name: storage-bench-piraeus-run-001
  namespace: storage-benchmark
  labels:
    app.kubernetes.io/name: storage-benchmark
    storage.compaan.io/backend: piraeus
spec:
  template:
    metadata:
      labels:
        app.kubernetes.io/name: storage-benchmark
        storage.compaan.io/backend: piraeus
    spec:
      restartPolicy: Never
      nodeSelector:
        storage.compaan.io/linstor-benchmark: "true"
      containers:
        - name: fio
          image: nixery.dev/shell/fio/jq/coreutils
          imagePullPolicy: IfNotPresent
          env:
            - name: BACKEND
              value: piraeus
```

Also change the PVC claim at the bottom to:

```yaml
      volumes:
        - name: fio-volume
          persistentVolumeClaim:
            claimName: piraeus-fio-pvc
```

Keep the same fio shell script body used in the Mayastor Job so both backends run identical profiles.

- [ ] **Step 7: Render the Piraeus manifests**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
kubectl kustomize argocd/base/piraeus-operator >/tmp/piraeus-operator-app.yaml
kubectl kustomize argocd/base/piraeus-benchmark >/tmp/piraeus-benchmark-app.yaml
kubectl kustomize argocd/homelab/piraeus-benchmark >/tmp/piraeus-benchmark-render.yaml
python3 - <<'PY'
from pathlib import Path
rendered = Path('/tmp/piraeus-benchmark-render.yaml').read_text()
for needle in [
    'kind: LinstorCluster',
    'kind: LinstorSatelliteConfiguration',
    'name: piraeus-bench-3r',
    'linstor.csi.linbit.com/placementCount: "3"',
    'storage-bench-piraeus-run-001',
]:
    assert needle in rendered, needle
print('piraeus manifests render successfully')
PY
```

Expected output:

```text
piraeus manifests render successfully
```

- [ ] **Step 8: Commit dormant Piraeus manifests**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
git add argocd/base/piraeus-operator argocd/base/piraeus-benchmark argocd/homelab/piraeus-benchmark
git commit -m "feat(storage): add Piraeus benchmark manifests"
```

Expected: commit succeeds. The apps are not live yet because `argocd/homelab/apps/kustomization.yaml` has not been changed.

---

### Task 11: Run the Piraeus/LINSTOR benchmark through GitOps

**Files:**
- Modify: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/apps/kustomization.yaml`
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/piraeus-run-001.log`

- [ ] **Step 1: Wire Piraeus apps into the bootstrap bundle**

Edit `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/apps/kustomization.yaml` and add these two resources after `../../base/longhorn-admission-hooks`:

```yaml
  - ../../base/piraeus-operator
  - ../../base/piraeus-benchmark
```

Expected: no Mayastor resources are present in this file during the Piraeus run.

- [ ] **Step 2: Render and commit the Piraeus activation**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
kubectl kustomize argocd/homelab/apps >/tmp/homelab-apps-with-piraeus.yaml
python3 - <<'PY'
from pathlib import Path
text = Path('/tmp/homelab-apps-with-piraeus.yaml').read_text()
assert 'name: piraeus-operator' in text
assert 'name: piraeus-benchmark' in text
assert 'name: openebs-mayastor' not in text
print('piraeus activation render verified')
PY
git add argocd/homelab/apps/kustomization.yaml
git commit -m "feat(storage): enable Piraeus benchmark"
```

Expected output includes:

```text
piraeus activation render verified
```

- [ ] **Step 3: Push the GitOps branch after operator confirmation**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
read -r -p 'Type push Piraeus benchmark GitOps activation: ' confirm
test "$confirm" = 'push Piraeus benchmark GitOps activation'
git push origin HEAD
```

Expected: push succeeds. If ArgoCD follows `main` only, merge or fast-forward this branch to the watched branch using the repository's normal review path, then wait for ArgoCD to reconcile.

- [ ] **Step 4: Watch Piraeus converge with read-only commands**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
KUBECONFIG=.kubeconfig kubectl -n argocd get applications piraeus-operator piraeus-benchmark
KUBECONFIG=.kubeconfig kubectl -n piraeus-datastore get pods -o wide
KUBECONFIG=.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor node list
KUBECONFIG=.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor storage-pool list
KUBECONFIG=.kubeconfig kubectl -n storage-benchmark get pvc,pod,job -o wide
```

Expected:

- `piraeus-operator` and `piraeus-benchmark` become Synced/Healthy in ArgoCD.
- LINSTOR lists `dauwalter`, `fordyce`, and `selassie` as online satellites.
- LINSTOR lists the `linstor-bench` storage pool on all three nodes.
- `piraeus-fio-pvc` binds.
- `storage-bench-piraeus-run-001` completes successfully.

- [ ] **Step 5: Collect Piraeus fio results**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n storage-benchmark logs job/storage-bench-piraeus-run-001 | tee docs/storage-benchmark/piraeus-run-001.log
scripts/summarize-storage-benchmark.py docs/storage-benchmark/piraeus-run-001.log | tee docs/storage-benchmark/piraeus-run-001-summary.md
git add docs/storage-benchmark/piraeus-run-001.log docs/storage-benchmark/piraeus-run-001-summary.md
git commit -m "perf(storage): record Piraeus benchmark results"
```

Expected:

- The log contains 18 `RESULT,piraeus,...` rows: 6 profiles x 3 passes.
- Summary generation exits 0.
- Commit succeeds.

- [ ] **Step 6: Record Piraeus health after the run**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
{
  echo '# Piraeus post-benchmark health'
  date -u
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore get pods -o wide
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor node list
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor storage-pool list
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list-volumes
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n storage-benchmark get pvc,pv,pod,job -o wide
} | tee docs/storage-benchmark/piraeus-run-001-health.md
git add docs/storage-benchmark/piraeus-run-001-health.md
git commit -m "docs(storage): record Piraeus benchmark health"
```

Expected: health file shows three online satellites, three storage pools, and the completed fio Job.

---

### Task 12: Observe Piraeus/LINSTOR degraded-node recovery

**Files:**
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/piraeus-recovery-observation.md`

- [ ] **Step 1: Confirm Piraeus starts healthy**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
{
  echo '# Piraeus recovery observation'
  date -u
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor node list
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor storage-pool list
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list-volumes
  KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n storage-benchmark get pvc,pod,job -o wide
} | tee docs/storage-benchmark/piraeus-recovery-observation.md
```

Expected: the benchmark PVC is bound, all three satellites are online, and the replicated resource is healthy before the outage.

- [ ] **Step 2: Reboot one Piraeus storage node with typed confirmation**

Use `selassie` as the recovery observation node.

Run:

```bash
read -r -p 'Type reboot selassie for Piraeus recovery observation: ' confirm
test "$confirm" = 'reboot selassie for Piraeus recovery observation'
ssh root@192.168.1.104 'systemctl reboot'
```

Expected: SSH disconnects because `selassie` reboots.

- [ ] **Step 3: Observe Piraeus during and after the reboot**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
for i in $(seq 1 30); do
  {
    echo
    echo "## observation ${i} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl get node selassie || true
    KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor node list || true
    KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list-volumes || true
    KUBECONFIG=/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/.kubeconfig kubectl -n storage-benchmark get pvc,pod -o wide || true
  } | tee -a docs/storage-benchmark/piraeus-recovery-observation.md
  sleep 30
done
```

Expected: `selassie` returns to `Ready`; LINSTOR eventually reports all three resources healthy again.

- [ ] **Step 4: Commit Piraeus recovery notes**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
git add docs/storage-benchmark/piraeus-recovery-observation.md
git commit -m "docs(storage): record Piraeus recovery observation"
```

Expected: commit succeeds.

---

### Task 13: Disable Piraeus benchmark resources through GitOps

**Files:**
- Modify: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/apps/kustomization.yaml`

- [ ] **Step 1: Remove Piraeus apps from the bootstrap bundle**

Edit `/home/roche/homelab-k8s/.worktrees/storage-benchmark/argocd/homelab/apps/kustomization.yaml` and remove these lines:

```yaml
  - ../../base/piraeus-operator
  - ../../base/piraeus-benchmark
```

- [ ] **Step 2: Render and commit Piraeus disablement**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
kubectl kustomize argocd/homelab/apps >/tmp/homelab-apps-after-piraeus.yaml
python3 - <<'PY'
from pathlib import Path
text = Path('/tmp/homelab-apps-after-piraeus.yaml').read_text()
assert 'name: piraeus-operator' not in text
assert 'name: piraeus-benchmark' not in text
print('piraeus disablement render verified')
PY
git add argocd/homelab/apps/kustomization.yaml
git commit -m "chore(storage): disable Piraeus benchmark"
```

Expected output includes:

```text
piraeus disablement render verified
```

- [ ] **Step 3: Push disablement after operator confirmation**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
read -r -p 'Type push Piraeus benchmark disablement: ' confirm
test "$confirm" = 'push Piraeus benchmark disablement'
git push origin HEAD
```

Expected: ArgoCD prunes Piraeus benchmark Applications after this change reaches the watched branch.

---

### Task 14: Produce the final backend decision note

**Files:**
- Create: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/final-comparison.md`
- Modify: `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/docs/specs/2026-06-20-linstor-mayastor-comparison.md`

- [ ] **Step 1: Generate the combined benchmark table**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
scripts/summarize-storage-benchmark.py \
  docs/storage-benchmark/mayastor-run-001.log \
  docs/storage-benchmark/piraeus-run-001.log \
  | tee docs/storage-benchmark/combined-summary.md
```

Expected: combined summary includes rows for both `mayastor` and `piraeus`.

- [ ] **Step 2: Write the final comparison document**

Create `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/final-comparison.md` with this structure and fill it from the collected logs, summaries, and recovery notes:

```markdown
# Storage Backend Benchmark Final Comparison

## Recommendation

Recommendation: defer both

## Benchmark Scope

- Nodes: `dauwalter`, `fordyce`, `selassie`
- Replication: 3 replicas
- PVC size: 10 GiB
- fio file size: 4 GiB
- Backend storage: disposable NVMe/LVM-backed benchmark pools

## Performance Summary

Paste the table from `docs/storage-benchmark/combined-summary.md` here.

## Operational Findings

| Dimension | Mayastor | LINSTOR/Piraeus |
| --- | --- | --- |
| NixOS host changes |  |  |
| GitOps manifest complexity |  |  |
| Initial convergence |  |  |
| Benchmark PVC provisioning |  |  |
| Degraded-node behavior |  |  |
| Recovery observability |  |  |
| Cleanup |  |  |

## Risks Accepted

- List only risks that remain after the benchmark evidence.

## Migration Gate

Before migrating any real app-state PVC, require:

- backend-specific monitoring and alerting
- documented restore path
- one non-critical app migration trial
- explicit rollback instructions
```

Before committing, keep `Recommendation: defer both` unless the benchmark evidence clearly supports changing it to exactly `Recommendation: Mayastor` or `Recommendation: LINSTOR/Piraeus`.

- [ ] **Step 3: Verify no unfilled comparison cells remain**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
python3 - <<'PY'
from pathlib import Path
text = Path('docs/storage-benchmark/final-comparison.md').read_text()
for forbidden in ['<choose exactly one', '| NixOS host changes |  |  |', '| GitOps manifest complexity |  |  |']:
    assert forbidden not in text, forbidden
print('final comparison has no template markers')
PY
```

Expected output:

```text
final comparison has no template markers
```

- [ ] **Step 4: Commit the final GitOps comparison artifacts**

Run:

```bash
cd /home/roche/homelab-k8s/.worktrees/storage-benchmark
git add docs/storage-benchmark/combined-summary.md docs/storage-benchmark/final-comparison.md
git commit -m "docs(storage): compare replicated storage benchmark results"
```

Expected: commit succeeds.

- [ ] **Step 5: Update the NixOS spec with the final decision link**

Edit `/home/roche/nixdots/.worktrees/mayastor-nvme-lvm/docs/specs/2026-06-20-linstor-mayastor-comparison.md` and add this section near the top after `## Decision`:

```markdown
## Benchmark Result

The benchmark execution artifacts live in `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/`.

Final comparison document: `/home/roche/homelab-k8s/.worktrees/storage-benchmark/docs/storage-benchmark/final-comparison.md`.
```

- [ ] **Step 6: Commit the NixOS spec update**

Run:

```bash
cd /home/roche/nixdots/.worktrees/mayastor-nvme-lvm
git add docs/specs/2026-06-20-linstor-mayastor-comparison.md
git commit -m "docs(storage): link benchmark comparison results"
```

Expected: commit succeeds.

---

## Testing and Verification Policy

Do not add new automated tests for static ArgoCD YAML, Nix option wiring, or one-off benchmark manifests. Use direct verification instead:

- `nix fmt` for Nix formatting.
- `nix build .#nixosConfigurations.dauwalter.config.system.build.toplevel`, `nix build .#nixosConfigurations.fordyce.config.system.build.toplevel`, and `nix build .#nixosConfigurations.selassie.config.system.build.toplevel` for selected host evaluation.
- `kubectl kustomize ...` for GitOps manifest rendering.
- `python3 -m py_compile scripts/summarize-storage-benchmark.py` for the summarizer script.
- A sample log run of `scripts/summarize-storage-benchmark.py` for behavior verification.
- Read-only `kubectl get`, `kubectl logs`, and backend CLI inspection for benchmark state and results.

## Rollback Plan

- To stop a live benchmark backend, remove only that backend's base Application entries from `argocd/homelab/apps/kustomization.yaml`, commit, push, and allow ArgoCD to prune.
- Do not manually delete PVs, PVCs, DiskPools, Linstor resources, or Helm releases from the workstation.
- If a storage backend fails to prune cleanly, stop and document the stuck resources before taking manual recovery action.
- Host disk layout rollback requires another destructive rolling reinstall and should not be attempted during benchmark comparison unless a selected node cannot rejoin the cluster.
