# OpenWRT Ziti DNS Upstream Design

## Problem

The r3 service starts `ziti-edge-tunnel` without `--dns-upstream`.

The tunnel resolver answers names for Ziti services. It returns `REFUSED` for public names because it has no upstream resolver.

The router uses dnsmasq at `127.0.0.1`. This resolver answers public names and reads its upstream servers from OpenWRT network state.

## Goals

- Forward non-Ziti DNS queries to the local dnsmasq service.
- Keep Ziti service-name interception active.
- Preserve existing router configuration during package upgrades.
- Keep the standalone procd entrypoint and the r3 lock fix unchanged.
- Support a different local resolver through UCI configuration.

## Non-goals

- Do not configure split DNS in dnsmasq.
- Do not change Ziti identities, policies, or service definitions.
- Do not change traffic interception beyond router-originated traffic.
- Do not change the operator update sequence.

## Configuration

Add `dns_upstream` to the package configuration. The packaged value is `127.0.0.1`.

Load the value with this default in `load_ziti_config`. Existing configuration files therefore receive the default without replacement.

The option stays configurable for routers that use a different local resolver.

## Service Command

Pass these DNS arguments to the tunnel process:

```text
--dns-ip-range 100.64.0.1/10
--dns-upstream <dns_upstream>
```

The default command forwards public DNS queries to dnsmasq at `127.0.0.1`.

The standalone `/usr/lib/ziti-edge-tunnel/run-managed` process remains the procd command. It does not source `/lib/functions/procd.sh`.

## Error Behavior

The init script validates `dns_upstream` as a canonical dotted-decimal IPv4 address before it starts the tunnel.

If the value is invalid or non-canonical, the service logs the configuration error and returns nonzero without starting the tunnel.

## Package Upgrade

Increase `PKG_RELEASE` from 3 to 4.

OpenWRT preserves an existing `/etc/config/ziti-edge-tunnel` file. The runtime default makes the new resolver behavior active after the upgrade.

The operator script installs the exact r4 IPK. OpenWRT maintainer scripts stop and start the enabled service.

## Automated Tests

Use test-driven development for the service change.

1. Add a service test that expects `--dns-upstream 127.0.0.1` with no configured value.
2. Run the test against r3 and record the expected failure.
3. Add the UCI option and service argument.
4. Add a service test that expects a configured upstream value.
5. Add a service test that rejects malformed, out-of-range, and non-canonical upstream values before tunnel launch.
6. Run all service and operator tests.
7. Build and validate the r4 IPK.
8. Run the full flake check.

The tests exercise the generated tunnel command. They do not only inspect static file text.

## Live Acceptance

Upgrade the router from r3 to r4 with `scripts/ziti-openwrt-tunnel.sh update`.

Verify these results:

- The update command returns without a timeout.
- The installed package is `1.15.1-r4`.
- `/etc/init.d/ziti-edge-tunnel running` returns promptly.
- procd supervises `/usr/lib/ziti-edge-tunnel/run-managed`.
- No long-lived process holds `procd_ziti-edge-tunnel.lock`.
- The identity remains mode `0600`.
- The enrollment JWT remains absent.
- The tunnel process remains active.
- `nslookup ha.compaan` returns a Ziti intercept address.
- `nslookup openwrt.org` returns a public address.
- The filtered tunnel log contains no new startup error for DNS forwarding.

Do not expose enrollment tokens or identity contents in acceptance evidence.
