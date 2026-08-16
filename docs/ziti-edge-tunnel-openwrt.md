# Ziti Edge Tunnel on ASUS RT-AX53U

This package targets OpenWRT 24.10.3 on `ramips/mt7621` (`mipsel_24kc`).
It gives processes running on the router access to Ziti services. It does not
route LAN clients through Ziti.

## Build

```sh
nix build .#ziti-edge-tunnel-openwrt
cat result/SHA256SUMS
```

## Operator script

`scripts/ziti-openwrt-tunnel.sh` wraps the install, update, and enrollment
flows. Without `--ipk <path>` it builds the package first; it copies the
package to the router with `scp` and drives `opkg` over SSH. The router
target defaults to `root@192.168.1.1` (override with `--router` or the
`ROUTER` environment variable).

Prerequisites on this workstation:

- SSH access to the router.
- For enrollment, the `ziti` CLI with an interactive login session:

```sh
ziti edge login ctrl.compaan.cloud:443 -u <username>
```

Install the package. The service stays disabled until enrollment:

```sh
scripts/ziti-openwrt-tunnel.sh install
```

Create the controller identity, generate its enrollment token, and enable
the service:

```sh
scripts/ziti-openwrt-tunnel.sh enroll --identity router-ax53u --attrs <dial-attributes>
```

`enroll` runs `ziti edge create identity <name> -o <jwt>`, keeping the JWT
in a temporary `0700` directory. It copies the JWT over SSH with
`umask 077` into `/etc/openziti/enroll.jwt`, deletes the local copy, then
enables and starts the service and waits for
`/etc/openziti/identities/router.json` to appear and for the router to
consume and remove the JWT. The JWT is never written to this repository.
`enroll` refuses to recreate an existing identity, because that would
invalidate the old enrollment; delete one deliberately first:

```sh
ziti edge delete identity "<name>"
```

Upgrade an installed package. The UCI conffile is preserved; the tunnel is
restarted only if it is currently running:

```sh
scripts/ziti-openwrt-tunnel.sh update
```

## Inspect status and logs

```sh
ssh "$ROUTER" '/etc/init.d/ziti-edge-tunnel running'
ssh "$ROUTER" "logread -e ziti-edge-tunnel | tail -100"
ssh "$ROUTER" 'ls -l /etc/openziti/identities/router.json; \
  test ! -e /etc/openziti/enroll.jwt'
```

## Verify router-local access

Set a URL served by a Ziti service assigned to this identity:

```sh
ZITI_SERVICE_URL=http://service.example.invalid
ssh "$ROUTER" "uclient-fetch -O- '$ZITI_SERVICE_URL'"
```

Replace the example URL in the shell variable; do not add a real private
service URL or credentials to Git.

Confirm ordinary router DNS still works:

```sh
ssh "$ROUTER" 'nslookup openwrt.org'
```

LAN routing, DHCP, and firewall configuration must remain unchanged.

## Stop and remove

```sh
ssh "$ROUTER" '/etc/init.d/ziti-edge-tunnel stop; \
  /etc/init.d/ziti-edge-tunnel disable; \
  uci set ziti-edge-tunnel.main.enabled=0; \
  uci commit ziti-edge-tunnel; \
  nslookup openwrt.org'
```

To uninstall while preserving the conffile behavior provided by `opkg`:

```sh
ssh "$ROUTER" 'opkg remove ziti-edge-tunnel'
```

Delete `/etc/openziti/identities/router.json` only when intentionally
revoking or replacing the router identity.
