# Homelab Overview

My homelab is running on k3s with GitOps-based deployments via Argo CD. An
OpenWrt router at `192.168.1.1` runs HAProxy and load‑balances across all
homelab nodes.

```
Internet / LAN → OpenWrt (HAProxy @ 192.168.1.1) → k3s Cluster (4 nodes)
                                                ↳ dauwalter
                                                ↳ kipsang
                                                ↳ fordyce
                                                ↳ walmsley
Git → Argo CD → Syncs applications into the cluster
```

## Networking & Ingress

- Router: OpenWrt at `192.168.1.1`
- Load balancer: HAProxy on the router
  - Purpose: Front-door for homelab services; balances traffic across all nodes
  - Backends: all homelab nodes (see above)
  - Typical traffic: HTTP(S) for app ingress; other ports as configured
