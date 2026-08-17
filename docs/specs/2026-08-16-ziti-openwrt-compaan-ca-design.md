# OpenWRT Compaan CA Trust Design

**Status:** Approved

## Context

The ASUS OpenWRT router runs `ziti-edge-tunnel` version `1.15.1-r4`. The tunnel intercepts `ha.compaan` and routes it to the private Traefik instance.

A static `/etc/hosts` entry previously mapped `ha.compaan` to `192.168.1.1`. This entry bypassed Ziti and reached the public Traefik instances. The router received their self-signed default certificates.

The static entry is now removed. Router applications resolve `ha.compaan` to the Ziti address `100.64.0.4`. The private endpoint presents a certificate for `ha.compaan` that `compaan-ca` issued.

A forced-path test with `compaan-ca.crt` returned HTTP 200. The same test with the default router trust failed with curl exit 60.

OpenWRT curl uses `/etc/ssl/certs/ca-certificates.crt`. The router has no `update-ca-certificates` command or local CA directory convention.

## Goals

- Trust `modules/nixos/core/certs/compaan-ca.crt` on the router.
- Keep CA trust coupled to the `ziti-edge-tunnel` package.
- Preserve the stock OpenWRT CA bundle.
- Repair CA trust during package installation and service startup.
- Remove the managed trust block during final package removal.
- Keep all existing tunnel, DNS, identity, and lock behavior.

## Non-goals

- The package does not manage `/etc/hosts`.
- The package does not change either Traefik instance.
- The change does not add a separate CA package.
- The change does not replace the OpenWRT `ca-bundle` package.
- The change does not send a production webhook during automated verification.

## Package release

The OpenWRT package release changes from `1.15.1-r4` to `1.15.1-r5`.

The existing operator script remains unchanged. Its normal update command builds and installs the r5 IPK.

## Package files

The Nix package tree copies the existing repository certificate into the generated OpenWRT package tree. The repository keeps one source copy of the certificate.

The IPK installs these new files:

- `/etc/ssl/certs/compaan-ca.crt`, mode `0644`
- `/usr/lib/ziti-edge-tunnel/update-ca-bundle`, mode `0755`

The IPK continues to depend on `ca-bundle` and `libopenssl`. It also depends on `openssl-util` for the helper commands.

## Bundle helper

The helper supports `ensure` and `remove` actions. It uses these fixed paths in production:

- source certificate: `/etc/ssl/certs/compaan-ca.crt`
- target bundle: `/etc/ssl/certs/ca-certificates.crt`
- lock file: `/tmp/lock/ziti-edge-tunnel-ca.lock`

Tests can override these paths with environment variables. Production package scripts do not set the overrides.

### Certificate validation

Before bundle modification, the helper validates the source certificate. It verifies these properties:

- OpenSSL can parse the certificate.
- The certificate has the `CA:TRUE` basic constraint.
- The certificate verifies against itself.
- Its file SHA-256 is `f0559a622ea96f65ce96b8e148aa1ceff104ad9852fe0f9dfcb1885815fce127`.
- Its SHA-256 fingerprint is `63:93:BC:6D:23:7E:19:14:0A:A2:4F:97:55:09:99:7A:D9:97:D5:EF:59:A5:61:18:E7:BF:0D:EA:33:F2:DD:06`.

A validation error stops the helper before it changes the bundle.

### Managed bundle block

The helper adds one marked block to the start of the stock bundle. The block contains the exact package certificate.

The block stays first because the router mbedTLS client does not load this CA after the full stock bundle.

The helper removes an existing managed block before it adds the new block. This operation makes repeated `ensure` actions idempotent.

The helper rejects malformed or unmatched markers. It does not change the bundle after this error.

The `remove` action removes only the marked block. It does not remove unrelated certificates.

### Atomic update and locking

The helper uses a non-service lock for bundle changes. This lock is independent of the procd service lock.

The lock must be root-owned with mode `0600`. The open descriptor and lock path must have the same inode.

The helper writes the new bundle to a temporary file in `/etc/ssl/certs`. It preserves the bundle mode and owner. It then renames the temporary file over the original bundle.

The helper removes its temporary file after an error. Concurrent helper calls serialize on the CA lock.

## Package lifecycle

The package post-install script runs `update-ca-bundle ensure` on a live router. It does not run the helper against an OpenWRT image staging root.

The init script runs `update-ca-bundle ensure` before it creates the procd instance. A helper error prevents tunnel launch.

The package refreshes the managed block during an upgrade. Final package removal runs `update-ca-bundle remove` while the source certificate still exists.

The package manager then removes the source certificate and helper. An upgrade can briefly remove and restore the block through the normal package lifecycle.

If `ca-bundle` replaces the bundle, the next package installation, upgrade, or service start restores the managed block. An in-place `ca-bundle` upgrade can remove trust until one of these events occurs.

## Error handling

The package fails closed when it cannot establish the required trust state. It does not launch the tunnel after helper failure.

The helper writes concise errors to stderr. The errors identify the failed validation or filesystem operation. They do not print certificate contents.

A failed bundle update leaves the original bundle unchanged. A failed removal also leaves the original bundle unchanged.

## Automated verification

Implementation follows test-driven development for the bundle helper and service integration.

Helper tests cover these behaviors:

- first installation adds one managed block.
- repeated installation keeps one managed block.
- installation restores a block after stock bundle replacement.
- removal deletes only the managed block.
- malformed markers stop modification.
- a missing or invalid source certificate stops modification.
- a substituted certificate fails fingerprint validation.
- concurrent updates serialize on the CA lock.
- failed updates preserve the original bundle.

Service tests verify that the helper runs before procd launch. They also verify that helper failure prevents tunnel launch.

IPK validation verifies these properties:

- package release r5.
- certificate and helper presence.
- file modes and ownership.
- expected CA fingerprint and basic constraint.
- package lifecycle scripts.
- existing binary, configuration, init, identity, and architecture checks.

Mutation tests reject an IPK with a missing certificate, a substituted certificate, or a missing helper.

The existing operator tests remain unchanged unless package selection must support extra output files. The final implementation runs the full flake check.

## Live acceptance

Before update, verify these conditions:

- the router runs r4.
- `/etc/hosts` has no `ha.compaan` entry.
- `ha.compaan` resolves to a Ziti synthetic address.
- curl fails only because the Compaan CA is absent.
- the procd lock has no long-lived holder.

Run the normal operator update from r4 to r5. The update must finish without an init-script hang.

After update, verify these conditions:

- opkg reports `ziti-edge-tunnel` version `1.15.1-r5`.
- the installed CA fingerprint matches the repository certificate.
- the managed bundle block occurs exactly once.
- `curl -fsS https://ha.compaan/` succeeds without `--cacert` or `--resolve`.
- the served certificate has the `ha.compaan` subject alternative name.
- procd supervises `/usr/lib/ziti-edge-tunnel/run-managed`.
- the tunnel command includes `--dns-upstream 127.0.0.1`.
- the procd lock has no long-lived holder.
- the identity remains nonempty with mode `0600`.
- the enrollment JWT remains absent.
- Ziti DNS and public DNS both resolve.
- filtered startup logs contain no new CA, DNS, or tunnel errors.

The live test does not use the production webhook URL or its secret path.

## Rollback

A downgrade to r4 runs the r5 removal lifecycle. This lifecycle removes the managed bundle block and the package-owned CA file.

The existing UCI configuration and enrolled identity remain package configuration data. The rollback must preserve both files.
