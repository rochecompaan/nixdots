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
`enroll` refuses to recreate an existing identity because that invalidates
the old enrollment. Delete one deliberately first:

```sh
ziti edge delete identity "<name>"
```

Upgrade an installed package. The UCI conffile is preserved; the tunnel is
restarted only if it is currently running:

```sh
scripts/ziti-openwrt-tunnel.sh update
```

## Compaan CA trust

Package release r5 and later install the Compaan CA at
`/etc/ssl/certs/compaan-ca.crt`. The package adds one marked block to the
start of `/etc/ssl/certs/ca-certificates.crt`.

The package refreshes the block after installation and before each service
start. The service does not start if this refresh fails. The package removes
the block before an upgrade, a downgrade, or package removal. The new package
installation restores the block after an upgrade.

An `/etc/hosts` entry takes priority over Ziti DNS for router applications.
For example, an old `ha.compaan` entry makes `curl` bypass the Ziti address.
`nslookup` can still show the Ziti address because it queries DNS directly.

Make sure that no obsolete host entry exists:

```sh
grep -nF 'ha.compaan' /etc/hosts
ping -c 1 ha.compaan
```

Then inspect the certificate from the Ziti service:

```sh
openssl s_client -connect ha.compaan:443 -servername ha.compaan </dev/null \
  | openssl x509 -noout -issuer -fingerprint -sha256 -ext subjectAltName
```

Finally, request the service with the system CA bundle:

```sh
curl -fsS https://ha.compaan/ -o /dev/null
```

Do not use `--cacert`, `--resolve`, or `-k` for this trust test.

## Compaan resolver routing

Package release r6 manages these dnsmasq rules through UCI:

```text
server=/compaan/
server=/ha.compaan/100.64.0.2
```

The specific rule sends `ha.compaan` to Ziti DNS. Ziti normally returns the
synthetic address `100.64.0.4`.

The broad rule answers unknown siblings, such as `unknown.compaan`, with local
data or NXDOMAIN. These private names do not reach public DNS. Public names
continue through the existing dnsmasq and WAN resolver path.

dnsmasq domain rules include descendant names. Therefore, r6 reserves the
`ha.compaan` subtree for Ziti. For example, `child.ha.compaan` also reaches
Ziti DNS.

The rules remain active when the Ziti service stops or becomes disabled. They
also remain active during package upgrades. If Ziti DNS is unavailable,
`ha.compaan` fails closed instead of using a public resolver.

The package records ownership for each rule in `/etc/config/ziti-edge-tunnel`.
It preserves an identical external rule. Final package removal removes only
rules that r6 owns.

Package installation and every service start repair a missing owned rule. A
repair error stops service startup before procd registration. An unchanged
rule set causes no UCI commit and no dnsmasq reload.

Use final removal before a rollback to r5:

```sh
opkg remove ziti-edge-tunnel
opkg install /tmp/ziti-edge-tunnel_1.15.1-r5_mipsel_24kc.ipk
```

Do not use a direct forced downgrade. Release r5 cannot remove r6 resolver
ownership state.

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
