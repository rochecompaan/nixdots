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

## OpenWrt VLANs

The OpenWrt router is an ASUS RT-AX53U running OpenWrt 24.10.3. The LAN bridge
uses DSA bridge VLAN filtering on `br-lan`.

### VLAN layout

| VLAN ID | Purpose | Device | Subnet | Ports |
| ---: | --- | --- | --- | --- |
| `1` | Trusted LAN | `br-lan.1` | `192.168.1.0/24` | `lan1`, `lan3` |
| `20` | Guest/IoT | `br-lan.20` | `192.168.20.0/24` | `lan2` |

Port membership:

| VLAN ID | `lan1` | `lan2` | `lan3` |
| ---: | --- | --- | --- |
| `1` | untagged + PVID | off | untagged + PVID |
| `20` | off | untagged + PVID | off |

`lan2` is an untagged Guest/IoT access port. A guest AP can be plugged into
`lan2` without VLAN tagging support; clients should receive `192.168.20.x`
addresses from OpenWrt.

### Guest/IoT interface

- Interface: `guest`
- Device: `br-lan.20`
- Router address: `192.168.20.1/24`
- DHCP range: `192.168.20.100` onward
- DHCP `Force` is enabled so dnsmasq serves the interface even if another DHCP
  server is detected on `br-lan.20`.

Relevant UCI settings:

```sh
network.lan.device='br-lan.1'
network.guest.device='br-lan.20'
network.guest.proto='static'
network.guest.ipaddr='192.168.20.1'
network.guest.netmask='255.255.255.0'

dhcp.guest.interface='guest'
dhcp.guest.start='100'
dhcp.guest.limit='150'
dhcp.guest.leasetime='12h'
dhcp.guest.dhcpv4='server'
dhcp.guest.force='1'
```

### Guest/IoT firewall

The `guest` firewall zone is isolated from the trusted LAN and only forwards to
WAN:

- Zone: `guest`
- Covered network: `guest`
- Input: `REJECT`
- Output: `ACCEPT`
- Forward: `REJECT`
- Forwarding: `guest` → `wan`

Allowed input rules from `guest` to the router:

- DHCP: UDP `67-68`
- DNS: TCP/UDP `53`

Do not add `guest` → `lan` forwarding unless Guest/IoT devices should be able to
reach trusted LAN services.
