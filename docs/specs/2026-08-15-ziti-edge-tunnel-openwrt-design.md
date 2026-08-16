# Ziti Edge Tunnel OpenWRT Package Design

## Status

Approved design for an initial OpenWRT package targeting one router and firmware release.

## Context

The target router is an ASUS RT-AX53U running OpenWRT 24.10.3. OpenWRT identifies this device as:

- target: `ramips/mt7621`
- package architecture: `mipsel_24kc`
- CPU family: little-endian MIPS 1004Kc

The existing `openziti-nix` input builds `ziti-edge-tunnel` for NixOS. That package uses NixOS runtime assumptions and cannot be installed on OpenWRT. OpenWRT uses a target-specific musl ABI, `opkg` packages, UCI configuration, and `procd` services.

The router will use Ziti only for traffic originating from processes on the router. It will not act as a Ziti gateway for other LAN devices.

## Goals

- Build an installable `ziti-edge-tunnel` `.ipk` with `nix build`.
- Use the exact OpenWRT SDK that matches the router firmware.
- Produce an OpenWRT-native package for `mipsel_24kc`.
- Install a UCI configuration and `procd` service.
- Enroll once from a JWT file, then remove the JWT after successful enrollment.
- Let router processes access Ziti services through a local TUN interface.
- Keep enrollment tokens, identities, certificates, and private keys out of Git and the Nix store.
- Preserve normal LAN behavior.

## Non-goals

- Building complete OpenWRT firmware images.
- Installing or upgrading router firmware.
- Forwarding LAN client traffic through Ziti.
- Changing LAN DHCP, dnsmasq forwarding rules, or firewall zones.
- Supporting other OpenWRT releases, targets, or host build architectures in the first version.
- Deploying the package automatically to the router.
- Moving the package builder into `openziti-nix` in the first version.

## Selected approach

Use a Nix derivation to provide a reproducible wrapper around the native OpenWRT SDK build.

Nix will pin and verify all build inputs. The OpenWRT SDK will perform the target compilation and create the `.ipk`. This keeps the result compatible with the router without treating OpenWRT as a NixOS target.

Pure nixpkgs cross-compilation is explicitly rejected because it would not provide the OpenWRT package ABI, dependency metadata, UCI files, or `procd` integration.

## Pinned inputs

### OpenWRT SDK

- release: `24.10.3`
- target: `ramips/mt7621`
- architecture: `mipsel_24kc`
- compiler: GCC 13.3.0
- C library: musl
- archive: `openwrt-sdk-24.10.3-ramips-mt7621_gcc-13.3.0_musl.Linux-x86_64.tar.zst`
- archive SHA-256: `c5800cce414b744b20260d137b7d4468501a1da9d453de282710a3b3b2085f1a`

The SDK comes from the official OpenWRT 24.10.3 download directory.

### OpenZiti

The initial package will pin `ziti-tunnel-sdk-c` release `v1.15.1`, matching the version currently packaged by the pinned `openziti-nix` input. Every source archive required by the build must have a Nix hash.

A later Ziti update changes only pinned versions, hashes, patches, and verified dependency metadata. It must not silently change the OpenWRT target.

## Repository structure

The implementation will follow the repository's existing flake-parts package pattern:

```text
modules/packages/ziti-edge-tunnel-openwrt.nix
nix/packages/ziti-edge-tunnel-openwrt/
  default.nix
  openwrt/
    Makefile
    files/
      etc/config/ziti-edge-tunnel
      etc/init.d/ziti-edge-tunnel
  tests/
    service-test.sh
```

The package module will expose:

```text
packages.x86_64-linux.ziti-edge-tunnel-openwrt
```

The package is a build artifact only. No NixOS or Home Manager configuration will add it to a host closure.

## Build architecture

The Nix derivation will:

1. Fetch and verify the exact OpenWRT SDK archive.
2. Fetch and verify the Ziti source and all dependency sources.
3. Unpack the SDK into a writable build directory.
4. Scan the SDK's generic Linux host executables and patch each dynamically linked ELF file with the NixOS interpreter and required runtime search paths.
5. Validate the SDK configuration before compiling:
   - release is `24.10.3`;
   - target is `ramips/mt7621`;
   - package architecture is `mipsel_24kc`.
6. Add the local `ziti-edge-tunnel` package recipe to the SDK.
7. Populate the SDK download cache from pinned Nix sources so the sandboxed build performs no network downloads.
8. Build only the package and its required target dependencies with the OpenWRT package build system.
9. Locate exactly one resulting `ziti-edge-tunnel` `.ipk`.
10. Validate the package and copy it into the Nix output with a SHA-256 checksum.

The primary command will be:

```sh
nix build .#ziti-edge-tunnel-openwrt
```

The result will contain a file named in this form:

```text
ziti-edge-tunnel_1.15.1-r1_mipsel_24kc.ipk
```

## OpenWRT package

The package recipe will use the OpenWRT CMake package helpers and target toolchain. It will disable systemd integration and tests that cannot run while cross-compiling.

The initial OpenWRT `DEPENDS` list will contain:

- `ca-bundle`
- `libjson-c5`
- `libopenssl3`
- `libpcap1`
- `libprotobuf-c`
- `libsodium`
- `libstdcpp6`
- `libuv1`
- `zlib`

Verification will compare the binary's `DT_NEEDED` entries with the OpenWRT package indexes. It will fail if a required shared library has no declared package. A dependency compiled into the binary will be removed from the runtime list rather than declared twice.

The package installation step will create:

```text
/usr/bin/ziti-edge-tunnel
/etc/config/ziti-edge-tunnel
/etc/init.d/ziti-edge-tunnel
/etc/openziti/identities/
```

The identities directory will be mode `0700`. The package will not install an identity or JWT.

## UCI contract

The default UCI configuration will be disabled:

```text
config ziti 'main'
        option enabled '0'
        option jwt '/etc/openziti/enroll.jwt'
        option identity '/etc/openziti/identities/router.json'
        option verbose '3'
```

Only file paths and non-secret runtime settings belong in UCI. The JWT and identity contents never belong in UCI.

The first version will not expose advanced routing, LAN forwarding, or DNS forwarding options. Additional options require a concrete use case and separate validation.

## Enrollment state machine

The `procd` init script will apply this state machine before launching the long-running process:

1. If `enabled` is false, exit without starting a process.
2. Create the identity directory if necessary and enforce mode `0700`.
3. If the identity file exists:
   - require it to be a regular file;
   - enforce mode `0600`;
   - skip enrollment.
4. If the identity does not exist:
   - require the configured JWT to be a regular file;
   - require mode `0600` or stricter;
   - run `ziti-edge-tunnel enroll --jwt "$jwt_path" --identity "$identity_path"`;
   - verify that enrollment exited successfully and created a non-empty identity file;
   - enforce identity mode `0600`;
   - remove the JWT only after all checks pass.
5. Start `ziti-edge-tunnel run --identity "$identity_path" --verbose "$verbose"` under `procd`.

Enrollment failure leaves the JWT in place and does not start the tunnel. If both identity and JWT exist, the existing identity wins and the JWT remains untouched; the service logs a warning rather than deleting an unused secret.

The service runs as root because it must create a TUN interface and routes. `procd` will supervise only the long-running `run` process and use bounded respawning to avoid a tight crash loop.

## Local routing and DNS

The service is for router-originated traffic only. It will not enable IP forwarding for Ziti, attach the TUN interface to a firewall zone, or change LAN DHCP responses.

`ziti-edge-tunnel` will create its local TUN interface and routes. For local hostname resolution, its existing generic Linux resolver path puts the embedded Ziti resolver first in `/etc/resolv.conf` when systemd-resolved and `resolvconf` are unavailable.

Because OpenWRT manages resolver files, the init integration will:

- record resolver state before starting the tunnel;
- allow Ziti to add only its local resolver entry;
- remove the Ziti entry on orderly shutdown or startup failure while preserving other current resolver entries;
- retain a runtime-only backup for recovery;
- never commit resolver state to persistent configuration.

Resolver backup files belong under `/tmp`, not `/etc`, and must not contain Ziti credentials. The cleanup logic must avoid restoring stale WAN DNS data over newer OpenWRT-generated data.

## Failure handling

The Nix build will fail when:

- a source or SDK hash changes;
- the SDK target or architecture does not match the design;
- a build step attempts an unpinned download;
- the OpenWRT package build fails;
- no `.ipk`, or more than one unexpected `.ipk`, is produced;
- package metadata does not declare `mipsel_24kc`;
- the payload lacks the binary, UCI file, or init script;
- the binary has the wrong ELF class, byte order, machine, interpreter, or unresolved shared library;
- package files have unsafe permissions.

At runtime, the service will log a clear error and remain stopped when configuration, enrollment, identity validation, TUN setup, or resolver setup fails. It will never delete a JWT after failed enrollment.

## Security

- All source inputs are pinned by cryptographic hashes.
- The package contains no enrollment material.
- The JWT is mode `0600` and exists only until successful enrollment.
- The identity directory is mode `0700`; identity files are mode `0600`.
- Logs must include paths and status but never JWT or private-key contents.
- UCI stores paths, not secrets.
- Nix builds never read router secrets.
- Installation remains an explicit administrator action using `opkg`.

## Verification strategy

### Automated behavior tests

A focused shell test harness will mock UCI, `procd`, and the `ziti-edge-tunnel` executable. It will prove reusable service behavior:

- an existing identity skips enrollment and starts the tunnel;
- a missing identity and missing JWT fails safely;
- a failed enrollment preserves the JWT and does not start the tunnel;
- successful enrollment creates the identity, removes the JWT, and starts the tunnel;
- an existing identity plus JWT preserves the unused JWT;
- disabled configuration starts nothing;
- resolver cleanup removes only the Ziti entry.

The enrollment tests must be developed with a red-green cycle.

### Direct build verification

Static package configuration will use direct verification rather than tests that merely restate file contents:

- run `nix fmt -- --check` or the repository formatter check;
- run the focused service tests;
- run `nix build .#ziti-edge-tunnel-openwrt`;
- inspect `.ipk` control metadata and payload;
- run shell syntax checks on the init script;
- inspect the binary with `file` and `readelf`;
- verify all `DT_NEEDED` libraries map to declared OpenWRT dependencies;
- run `nix flake check --accept-flake-config --print-build-logs`.

### On-router acceptance

After copying the package to the router:

1. Install it with `opkg install` and allow `opkg` to resolve declared dependencies.
2. Confirm `ziti-edge-tunnel version` runs.
3. Copy a JWT to `/etc/openziti/enroll.jwt` with mode `0600`.
4. Enable the UCI service and start it.
5. Confirm the JWT is removed only after an identity is created.
6. Confirm the service remains active and survives a router reboot.
7. Access a known Ziti service from a process running on the router.
8. Confirm ordinary router DNS still works.
9. Confirm LAN clients retain their previous routing and DNS behavior.
10. Stop the service and confirm local resolver state is clean.

## Acceptance criteria

The work is complete when:

- `nix build .#ziti-edge-tunnel-openwrt` produces one valid `mipsel_24kc` `.ipk` for OpenWRT 24.10.3;
- the build is network-free after Nix fetches its declared fixed-output sources;
- automated service tests pass;
- repository checks pass;
- the package installs on the ASUS RT-AX53U;
- one-time JWT enrollment behaves as specified;
- a router process can access a Ziti service;
- router DNS remains usable before, during, and after the service;
- LAN clients are unaffected;
- no secret enters Git or the Nix store.

## Future extension

If the package needs to support multiple routers or OpenWRT releases, move the reusable builder and package recipe to `openziti-nix`. `nixdots` can then pin and re-export a target-specific package. That migration is outside this initial scope.

## References

- [OpenZiti OpenWRT build guide](https://github.com/openziti/ziti-tunnel-sdk-c/blob/main/docs/openwrt/BUILDING.md)
- [OpenWRT SDK guide](https://openwrt.org/docs/guide-developer/toolchain/using_the_sdk)
- [OpenWRT ASUS RT-AX53U device page](https://openwrt.org/toh/asus/rt-ax53u)
- [OpenWRT 24.10.3 ramips/mt7621 downloads](https://downloads.openwrt.org/releases/24.10.3/targets/ramips/mt7621/)
