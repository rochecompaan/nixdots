# Ziti Edge Tunnel OpenWRT Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reproducible `nix build .#ziti-edge-tunnel-openwrt` target that produces a secure, service-integrated `mipsel_24kc` `.ipk` for an ASUS RT-AX53U running OpenWRT 24.10.3.

**Architecture:** Nix pins and prepares the x86_64 OpenWRT SDK plus all OpenZiti sources. The OpenWRT package build system performs the MIPS/musl compilation and creates the `.ipk`; a UCI-driven `procd` service handles one-time JWT enrollment and router-local tunneling. A fixed-output OpenWRT download cache permits network fetches once while the final package build remains sandboxed and network-free.

**Tech Stack:** Nix flakes and flake-parts, OpenWRT SDK 24.10.3, OpenWRT package Makefiles, CMake, POSIX shell, `procd`, UCI, Bash test harness, `file`, `readelf`, and `opkg`/`.ipk` archives.

## Global Constraints

- Design source: `docs/specs/2026-08-15-ziti-edge-tunnel-openwrt-design.md`.
- Build host: `x86_64-linux` only.
- Router: ASUS RT-AX53U.
- OpenWRT release: `24.10.3`.
- OpenWRT target: `ramips/mt7621`.
- Package architecture: `mipsel_24kc`.
- OpenWRT SDK archive: `openwrt-sdk-24.10.3-ramips-mt7621_gcc-13.3.0_musl.Linux-x86_64.tar.zst`.
- OpenWRT SDK hash: `sha256-xYAMzkFLdEsgJg0Te31EaFAaHanUU94oJxCjs7IIXxo=`.
- Ziti tunnel release: `v1.15.1`; Ziti SDK release: `1.15.0`.
- The result is a build artifact; do not add it to a NixOS or Home Manager closure.
- Runtime scope is router-originated traffic only. Do not add LAN forwarding, DHCP, dnsmasq forwarding, or firewall-zone changes.
- Keep JWTs, identities, certificates, and private keys out of Git and the Nix store.
- Delete the JWT only after enrollment exits successfully and creates a non-empty identity.
- Build and service failures must stop safely and preserve enrollment material.
- Apply the Testing Value Gate: test service state transitions and package parsing; verify static Nix/OpenWRT configuration directly.
- Follow TDD for service behavior and package validation.
- Keep exactly one writing agent in the worktree.
- Use signed Conventional Commits; never bypass hooks or signing.

---

## File Map

| Path | Responsibility |
| --- | --- |
| `flake.nix` | Import the new flake-parts package module. |
| `modules/packages/ziti-edge-tunnel-openwrt.nix` | Expose the package and its focused flake checks. |
| `nix/packages/ziti-edge-tunnel-openwrt/default.nix` | Pin sources, prepare the SDK, build the fixed-output download cache, run the OpenWRT package build, and publish the `.ipk`. |
| `nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile` | Define the OpenWRT package, target dependencies, CMake options, conffile, and payload. |
| `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel` | Provide disabled-by-default UCI settings containing paths only. |
| `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel` | Validate secrets, enroll once, supervise the tunnel, and clean the local resolver entry. |
| `nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh` | Mock UCI, `procd`, and Ziti to prove service lifecycle behavior. |
| `nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh` | Validate control metadata, payload, modes, MIPS/musl ELF properties, and shared-library dependency mapping. |
| `docs/ziti-edge-tunnel-openwrt.md` | Document build, install, enrollment, operation, rollback, and router acceptance steps. |

The package remains focused in one `default.nix`; source preparation helpers are local derivations in its `let` block. If implementation pushes that file past roughly 250 lines, extract SDK preparation into `nix/packages/ziti-edge-tunnel-openwrt/sdk.nix` without changing the public package interface.

---

### Task 1: Build the UCI and `procd` Service with TDD

**Files:**
- Create: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel`
- Create: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel`
- Create: `nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh`

**Interfaces:**
- Consumes: OpenWRT `/etc/rc.common`, UCI functions `config_load`, `config_get`, and `config_get_bool`, plus `procd_*` functions.
- Produces: UCI section `ziti-edge-tunnel.main`; shell functions `load_ziti_config`, `validate_jwt`, `prepare_identity`, `snapshot_resolver`, `cleanup_resolver`, `start_service`, `stop_service`, and `service_triggers`.
- Runtime constants: `DNS_CIDR=100.64.0.1/10` and `ZITI_DNS=100.64.0.2`.
- Test overrides: `ZITI_PROG`, `ZITI_RUNTIME_DIR`, and `ZITI_RESOLV_CONF` environment variables.

- [ ] **Step 1: Write the service test harness before the init script**

Create `nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh` with a case runner that sources the init script under Bash while mocking OpenWRT functions. Use this structure and include all seven cases listed below:

```bash
#!/usr/bin/env bash
set -euo pipefail

init_script=${1:?usage: service-test.sh /path/to/init-script}
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() { [[ -f $1 ]] || fail "expected file: $1"; }
assert_no_file() { [[ ! -e $1 ]] || fail "expected no file: $1"; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "$1 contains: $2"; }

run_case() (
  set -euo pipefail
  name=$1
  shift
  root="$test_root/$name"
  mkdir -p "$root/bin" "$root/etc/openziti/identities" "$root/run"

  export ZITI_PROG="$root/bin/ziti-edge-tunnel"
  export ZITI_RUNTIME_DIR="$root/run"
  export ZITI_RESOLV_CONF="$root/resolv.conf"
  export TEST_ENABLED=1
  export TEST_JWT="$root/etc/openziti/enroll.jwt"
  export TEST_IDENTITY="$root/etc/openziti/identities/router.json"
  export TEST_VERBOSE=3
  export TEST_ENROLL_RESULT=success
  : >"$root/procd-command"
  printf 'nameserver 192.0.2.53\n' >"$ZITI_RESOLV_CONF"

  cat >"$ZITI_PROG" <<'MOCK'
#!/bin/sh
set -eu
if [ "$1" = enroll ]; then
  shift
  identity=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --identity) identity=$2; shift 2 ;;
      --jwt) shift 2 ;;
      *) shift ;;
    esac
  done
  [ "${TEST_ENROLL_RESULT:-failure}" = success ] || exit 23
  printf '{"ztAPI":"https://controller.invalid"}\n' >"$identity"
  exit 0
fi
exit 64
MOCK
  chmod 0755 "$ZITI_PROG"

  config_load() { [ "$1" = ziti-edge-tunnel ]; }
  config_get_bool() { printf -v "$1" '%s' "$TEST_ENABLED"; }
  config_get() {
    case "$3" in
      jwt) printf -v "$1" '%s' "$TEST_JWT" ;;
      identity) printf -v "$1" '%s' "$TEST_IDENTITY" ;;
      verbose) printf -v "$1" '%s' "$TEST_VERBOSE" ;;
      *) printf -v "$1" '%s' "${4-}" ;;
    esac
  }
  logger() { printf '%s\n' "$*" >>"$root/log"; }
  procd_open_instance() { :; }
  procd_set_param() {
    if [ "$1" = command ]; then
      shift
      printf '%s\n' "$*" >"$root/procd-command"
    fi
  }
  procd_close_instance() { :; }
  procd_add_reload_trigger() { :; }

  # shellcheck source=/dev/null
  source "$init_script"
  "$@"
)

case_disabled() {
  TEST_ENABLED=0
  start_service
  [[ ! -s $root/procd-command ]] || fail 'disabled service started a process'
}

case_existing_identity() {
  printf '{}\n' >"$TEST_IDENTITY"
  chmod 0644 "$TEST_IDENTITY"
  start_service
  assert_contains "$root/procd-command" "run --identity $TEST_IDENTITY"
  [[ $(stat -c %a "$TEST_IDENTITY") = 600 ]] || fail 'identity mode was not corrected'
}

case_missing_material() {
  if start_service; then fail 'missing identity and JWT succeeded'; fi
  [[ ! -s $root/procd-command ]] || fail 'missing material started a process'
}

case_failed_enrollment() {
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  export TEST_ENROLL_RESULT=failure
  if start_service; then fail 'failed enrollment succeeded'; fi
  assert_file "$TEST_JWT"
  assert_no_file "$TEST_IDENTITY"
}

case_successful_enrollment() {
  printf 'signed.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  start_service
  assert_file "$TEST_IDENTITY"
  assert_no_file "$TEST_JWT"
  assert_contains "$root/procd-command" "--dns-ip-range 100.64.0.1/10"
}

case_existing_identity_preserves_jwt() {
  printf '{}\n' >"$TEST_IDENTITY"
  printf 'unused.jwt\n' >"$TEST_JWT"
  chmod 0600 "$TEST_JWT"
  start_service
  assert_file "$TEST_JWT"
  assert_contains "$root/log" 'identity already exists; leaving JWT untouched'
}

case_resolver_cleanup() {
  printf 'nameserver 100.64.0.2\nnameserver 192.0.2.53\nsearch lan\n' >"$ZITI_RESOLV_CONF"
  cleanup_resolver
  assert_not_contains "$ZITI_RESOLV_CONF" 'nameserver 100.64.0.2'
  assert_contains "$ZITI_RESOLV_CONF" 'nameserver 192.0.2.53'
  assert_contains "$ZITI_RESOLV_CONF" 'search lan'
}

run_case disabled case_disabled
run_case existing-identity case_existing_identity
run_case missing-material case_missing_material
run_case failed-enrollment case_failed_enrollment
run_case successful-enrollment case_successful_enrollment
run_case existing-identity-jwt case_existing_identity_preserves_jwt
run_case resolver-cleanup case_resolver_cleanup
printf 'service tests: 7 passed\n'
```

- [ ] **Step 2: Run the test and verify the red state**

Run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel
```

Expected: FAIL because the init script does not exist. This proves the harness is exercising the intended file rather than passing without an implementation.

- [ ] **Step 3: Add the disabled-by-default UCI configuration**

Create `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel`:

```text
config ziti 'main'
        option enabled '0'
        option jwt '/etc/openziti/enroll.jwt'
        option identity '/etc/openziti/identities/router.json'
        option verbose '3'
```

Do not add JWT content or identity content.

- [ ] **Step 4: Implement the minimal secure `procd` init script**

Create `nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel`:

```sh
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=95
STOP=10

PROG=${ZITI_PROG:-/usr/bin/ziti-edge-tunnel}
RUNTIME_DIR=${ZITI_RUNTIME_DIR:-/tmp/ziti-edge-tunnel}
RESOLV_CONF=${ZITI_RESOLV_CONF:-/etc/resolv.conf}
DNS_CIDR=100.64.0.1/10
ZITI_DNS=100.64.0.2

log() {
        logger -t ziti-edge-tunnel -- "$*"
}

load_ziti_config() {
        config_load ziti-edge-tunnel
        config_get_bool enabled main enabled 0
        config_get jwt_path main jwt /etc/openziti/enroll.jwt
        config_get identity_path main identity /etc/openziti/identities/router.json
        config_get verbose main verbose 3

        [ -n "$jwt_path" ] || { log 'JWT path is empty'; return 1; }
        [ -n "$identity_path" ] || { log 'identity path is empty'; return 1; }
        case "$verbose" in
                ''|*[!0-9]*) log 'verbose must be numeric'; return 1 ;;
        esac
}

validate_jwt() {
        [ -f "$jwt_path" ] && [ ! -L "$jwt_path" ] || {
                log "JWT is missing or is not a regular file: $jwt_path"
                return 1
        }

        mode=$(stat -c %a "$jwt_path") || return 1
        permissions=$((0$mode))
        [ $((permissions & 0077)) -eq 0 ] || {
                log "JWT permissions are too broad: $jwt_path"
                return 1
        }
        [ $((permissions & 0400)) -ne 0 ] || {
                log "JWT is not owner-readable: $jwt_path"
                return 1
        }
}

prepare_identity() {
        identity_dir=${identity_path%/*}
        [ "$identity_dir" != "$identity_path" ] || {
                log "identity path has no parent directory: $identity_path"
                return 1
        }

        umask 077
        mkdir -p "$identity_dir" || return 1
        chmod 0700 "$identity_dir" || return 1

        if [ -f "$identity_path" ] && [ ! -L "$identity_path" ]; then
                chmod 0600 "$identity_path" || return 1
                if [ -e "$jwt_path" ]; then
                        log 'identity already exists; leaving JWT untouched'
                fi
                return 0
        fi

        [ ! -e "$identity_path" ] || {
                log "identity exists but is not a regular file: $identity_path"
                return 1
        }
        validate_jwt || return 1

        if ! "$PROG" enroll --jwt "$jwt_path" --identity "$identity_path"; then
                rm -f "$identity_path"
                log 'enrollment failed; JWT preserved'
                return 1
        fi
        [ -s "$identity_path" ] || {
                rm -f "$identity_path"
                log 'enrollment produced no identity; JWT preserved'
                return 1
        }

        chmod 0600 "$identity_path" || return 1
        rm -f "$jwt_path" || {
                log 'identity created but JWT removal failed'
                return 1
        }
        log 'enrollment completed and JWT removed'
}

snapshot_resolver() {
        umask 077
        mkdir -p "$RUNTIME_DIR" || return 1
        chmod 0700 "$RUNTIME_DIR" || return 1
        if [ -r "$RESOLV_CONF" ]; then
                cp -L "$RESOLV_CONF" "$RUNTIME_DIR/resolv.conf.before" || return 1
                chmod 0600 "$RUNTIME_DIR/resolv.conf.before" || return 1
        fi
}

cleanup_resolver() {
        [ -f "$RESOLV_CONF" ] || return 0
        mkdir -p "$RUNTIME_DIR" || return 1
        cleaned="$RUNTIME_DIR/resolv.conf.cleaned"
        awk -v dns="$ZITI_DNS" '$0 != "nameserver " dns { print }' \
                "$RESOLV_CONF" >"$cleaned" || return 1
        cat "$cleaned" >"$RESOLV_CONF" || return 1
        rm -f "$cleaned" "$RUNTIME_DIR/resolv.conf.before"
}

start_service() {
        load_ziti_config || return 1
        [ "$enabled" -eq 1 ] || return 0
        prepare_identity || return 1
        snapshot_resolver || return 1

        procd_open_instance ziti-edge-tunnel
        procd_set_param command "$PROG" run \
                --identity "$identity_path" \
                --verbose "$verbose" \
                --dns-ip-range "$DNS_CIDR"
        procd_set_param respawn 3600 5 5
        procd_set_param term_timeout 10
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance || {
                cleanup_resolver
                return 1
        }
}

stop_service() {
        cleanup_resolver
}

service_triggers() {
        procd_add_reload_trigger ziti-edge-tunnel
}
```

The exact resolver line is deterministic because `100.64.0.1/10` gives the tunnel `100.64.0.1` and Ziti DNS `100.64.0.2` in upstream `v1.15.1`.

- [ ] **Step 5: Run the service tests and syntax check**

Run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel
sh -n nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel
```

Expected:

```text
service tests: 7 passed
```

`sh -n` must exit 0.

- [ ] **Step 6: Commit the tested service behavior**

```bash
git add \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/config/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel \
  nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh
git commit -m "feat(ziti): add OpenWRT service lifecycle"
```

---

### Task 2: Build the OpenWRT Package through Nix

**Files:**
- Create: `nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile`
- Create: `nix/packages/ziti-edge-tunnel-openwrt/default.nix`
- Create: `modules/packages/ziti-edge-tunnel-openwrt.nix`
- Modify: `flake.nix:102-108`

**Interfaces:**
- Consumes: Task 1's UCI file, init script, and `service-test.sh`.
- Produces: `packages.x86_64-linux.ziti-edge-tunnel-openwrt`, `checks.x86_64-linux.ziti-edge-tunnel-openwrt-service`, and an output directory containing one `.ipk` plus `SHA256SUMS`.
- The OpenWRT package template consumes substituted Nix store paths named `zitiTunnelSrc`, `zitiSdkSrc`, `lwipSrc`, `lwipContribSrc`, `subcommandSrc`, and `tlsuvSrc`.

- [ ] **Step 1: Add a flake module whose package import initially fails**

Create `modules/packages/ziti-edge-tunnel-openwrt.nix`:

```nix
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      ziti-edge-tunnel-openwrt = import ../../nix/packages/ziti-edge-tunnel-openwrt { inherit pkgs; };
    in
    {
      packages.ziti-edge-tunnel-openwrt = ziti-edge-tunnel-openwrt;
      checks.ziti-edge-tunnel-openwrt-build = ziti-edge-tunnel-openwrt;
      checks.ziti-edge-tunnel-openwrt-service = pkgs.runCommand "ziti-edge-tunnel-openwrt-service-test" {
        nativeBuildInputs = [ pkgs.bash ];
      } ''
        bash ${../../nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh} \
          ${../../nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel}
        touch $out
      '';
    };
}
```

Import it in `flake.nix` before `streamlinear.nix`:

```nix
      imports = [
        ./hosts
        ./home
        ./modules/packages/ziti-edge-tunnel-openwrt.nix
        ./modules/packages/streamlinear.nix
        ./pre-commit-hooks.nix
      ];
```

- [ ] **Step 2: Verify the package output is red before adding the derivation**

Because the new paths are untracked, evaluate the path flake:

```bash
nix build --impure --expr \
  '(builtins.getFlake "path:'"$PWD"'").packages.x86_64-linux.ziti-edge-tunnel-openwrt'
```

Expected: FAIL because `nix/packages/ziti-edge-tunnel-openwrt/default.nix` does not exist. The service check remains independently runnable with Task 1's command.

- [ ] **Step 3: Add the OpenWRT package Makefile**

Create `nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile`:

```make
include $(TOPDIR)/rules.mk

PKG_NAME:=ziti-edge-tunnel
PKG_VERSION:=1.15.1
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Roché Compaan
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1

ZITI_TUNNEL_SRC:=@zitiTunnelSrc@
ZITI_SDK_SRC:=@zitiSdkSrc@
LWIP_SRC:=@lwipSrc@
LWIP_CONTRIB_SRC:=@lwipContribSrc@
SUBCOMMAND_SRC:=@subcommandSrc@
TLSUV_SRC:=@tlsuvSrc@

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/ziti-edge-tunnel
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OpenZiti edge tunneler
  URL:=https://openziti.io/
  DEPENDS:=+ca-bundle +libatomic1 +libjson-c5 +libopenssl3 +libpcap1 +libprotobuf-c +libsodium +libstdcpp6 +libuv1 +zlib
endef

define Package/ziti-edge-tunnel/description
  OpenZiti edge tunneler packaged for router-originated traffic on OpenWRT.
endef

define Package/ziti-edge-tunnel/conffiles
/etc/config/ziti-edge-tunnel
endef

define Build/Prepare
	$(RM) $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) $(ZITI_TUNNEL_SRC)/. $(PKG_BUILD_DIR)/
	$(RM) $(PKG_BUILD_DIR)/deps/lwip
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/deps/lwip
	$(CP) $(LWIP_SRC)/. $(PKG_BUILD_DIR)/deps/lwip/
	chmod -R u+w $(PKG_BUILD_DIR)
endef

CMAKE_OPTIONS += \
	-DBUILD_DIST_PACKAGES=OFF \
	-DBUILD_EXAMPLES=OFF \
	-DBUILD_SHARED_LIBS=OFF \
	-DBUILD_STATIC_LIBS=ON \
	-DCMAKE_BUILD_TYPE=Release \
	-DDISABLE_LIBSYSTEMD_FEATURE=ON \
	-DDISABLE_SEMVER_VERIFICATION=ON \
	-DENABLE_VCPKG=OFF \
	-DFETCHCONTENT_FULLY_DISCONNECTED=ON \
	-DFETCHCONTENT_SOURCE_DIR_LWIP=$(PKG_BUILD_DIR)/deps/lwip \
	-DFETCHCONTENT_SOURCE_DIR_LWIP-CONTRIB=$(LWIP_CONTRIB_SRC) \
	-DFETCHCONTENT_SOURCE_DIR_SUBCOMMAND=$(SUBCOMMAND_SRC) \
	-DGIT_VERSION=v$(PKG_VERSION) \
	-DTLSUV_TLSLIB=openssl \
	-DZITI_SDK_DIR=$(ZITI_SDK_SRC) \
	-DZITI_SDK_VERSION=1.15.0 \
	-DZITI_TUNNEL_BUILD_TESTS=OFF \
	-Dtlsuv_DIR=$(TLSUV_SRC)

define Package/ziti-edge-tunnel/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ziti-edge-tunnel $(1)/usr/bin/ziti-edge-tunnel
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ziti-edge-tunnel $(1)/etc/config/ziti-edge-tunnel
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ziti-edge-tunnel $(1)/etc/init.d/ziti-edge-tunnel
	$(INSTALL_DIR) $(1)/etc/openziti/identities
	chmod 0700 $(1)/etc/openziti/identities
endef

$(eval $(call BuildPackage,ziti-edge-tunnel))
```

`libatomic1` is included because `ziti-sdk-c` links `atomic` on Linux. `llhttp` and STC are built or included from pinned source in the Nix derivation and are not runtime packages.

- [ ] **Step 4: Add the pinned Nix builder with a deliberate fixed-output hash probe**

Create `nix/packages/ziti-edge-tunnel-openwrt/default.nix`. Keep the source pins and derivation composition in this file:

```nix
{ pkgs }:
let
  inherit (pkgs) lib;

  version = "1.15.1";
  openwrtVersion = "24.10.3";
  target = "ramips/mt7621";
  architecture = "mipsel_24kc";

  openwrtSdkArchive = pkgs.fetchurl {
    url = "https://downloads.openwrt.org/releases/${openwrtVersion}/targets/${target}/openwrt-sdk-${openwrtVersion}-ramips-mt7621_gcc-13.3.0_musl.Linux-x86_64.tar.zst";
    hash = "sha256-xYAMzkFLdEsgJg0Te31EaFAaHanUU94oJxCjs7IIXxo=";
  };

  zitiTunnelSrc = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "ziti-tunnel-sdk-c";
    rev = "v${version}";
    hash = "sha256-ZSTurUxd5tsnK/cCEynKLjSoaJUCOJQNLZ9RE5Mf3oU=";
  };

  zitiSdkBase = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "ziti-sdk-c";
    tag = "1.15.0";
    hash = "sha256-o1Hcrqz+e2vJZjnPxIAgy5xKwu+M24o/Knh99dwTR3I=";
  };

  lwipSrc = pkgs.fetchFromGitHub {
    owner = "lwip-tcpip";
    repo = "lwip";
    rev = "STABLE-2_2_1_RELEASE";
    hash = "sha256-8TYbUgHNv9SV3l203WVfbwDEHFonDAQqdykiX9OoM34=";
  };

  lwipContribSrc = pkgs.fetchFromGitHub {
    owner = "netfoundry";
    repo = "lwip-contrib";
    rev = "STABLE-2_1_0_RELEASE";
    hash = "sha256-Ypn/QfkiTGoKLCQ7SXozk4D/QIdo4lyza4yq3tAoP/0=";
  };

  subcommandSrc = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "subcommands.c";
    rev = "87350797774530b6ba9c00017f0f53dd57e6c38e";
    hash = "sha256-Gz0/b9jcC1I0fmguSMkV0xiqKWq7vzUVT0Bd1F4iqkA=";
  };

  tlsuvBase = pkgs.fetchFromGitHub {
    owner = "openziti";
    repo = "tlsuv";
    rev = "v0.41.1";
    hash = "sha256-mT1K8OpwE+brdEc6ik8jMhEsXGuEh5nqfY3urx7IQiA=";
  };

  zitiSdkSrc = pkgs.runCommand "ziti-sdk-c-1.15.0-openwrt-src" { } ''
    cp -R ${zitiSdkBase} $out
    chmod -R u+w $out
    substituteInPlace $out/library/CMakeLists.txt \
      --replace-fail \
        'pkg_check_modules(STC REQUIRED IMPORTED_TARGET stc)' \
        'add_library(PkgConfig::STC INTERFACE IMPORTED)
set_target_properties(PkgConfig::STC PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${pkgs.stc.src}/include")'
  '';

  tlsuvSrc = pkgs.runCommand "tlsuv-0.41.1-openwrt-src" { } ''
    cp -R ${tlsuvBase} $out
    chmod -R u+w $out
    substituteInPlace $out/CMakeLists.txt \
      --replace-fail \
        '    find_package(llhttp CONFIG REQUIRED)' \
        '    add_subdirectory("${pkgs.llhttp.src}" "''${CMAKE_CURRENT_BINARY_DIR}/llhttp" EXCLUDE_FROM_ALL)'
  '';

  packageTree = pkgs.runCommand "ziti-edge-tunnel-openwrt-package-tree" { } ''
    cp -R ${./openwrt} $out
    chmod -R u+w $out
    substituteInPlace $out/Makefile \
      --subst-var-by zitiTunnelSrc ${zitiTunnelSrc} \
      --subst-var-by zitiSdkSrc ${zitiSdkSrc} \
      --subst-var-by lwipSrc ${lwipSrc} \
      --subst-var-by lwipContribSrc ${lwipContribSrc} \
      --subst-var-by subcommandSrc ${subcommandSrc} \
      --subst-var-by tlsuvSrc ${tlsuvSrc}
  '';

  hostLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.ncurses
    pkgs.libxcrypt
    pkgs.util-linux.lib
    pkgs.xz
    pkgs.zstd
  ];

  nativeTools = [
    pkgs.bash
    pkgs.binutils
    pkgs.coreutils
    pkgs.diffutils
    pkgs.file
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnumake
    pkgs.gnused
    pkgs.gnutar
    pkgs.patch
    pkgs.patchelf
    pkgs.perl
    pkgs.pkg-config
    pkgs.python3
    pkgs.rsync
    pkgs.stdenv.cc
    pkgs.unzip
    pkgs.util-linux
    pkgs.which
    pkgs.xz
    pkgs.zstd
  ];

  preparedSdk = pkgs.stdenvNoCC.mkDerivation {
    pname = "openwrt-sdk-prepared";
    version = openwrtVersion;
    src = openwrtSdkArchive;
    nativeBuildInputs = nativeTools;
    dontFixup = true;
    dontStrip = true;

    unpackPhase = ''
      runHook preUnpack
      mkdir source
      tar --zstd -xf $src -C source --strip-components=1
      cd source
      runHook postUnpack
    '';

    buildPhase = ''
      runHook preBuild
      chmod -R u+w .
      patchShebangs .
      while IFS= read -r -d "" candidate; do
        description=$(file -b "$candidate" || true)
        case "$description" in
          *"ELF 64-bit LSB"*"x86-64"*"dynamically linked"*)
            old_rpath=$(patchelf --print-rpath "$candidate" 2>/dev/null || true)
            patchelf --set-interpreter "${pkgs.stdenv.cc.bintools.dynamicLinker}" "$candidate"
            patchelf --set-rpath "${hostLibraryPath}''${old_rpath:+:$old_rpath}" "$candidate"
            ;;
        esac
      done < <(find . -type f -perm -0100 -print0)
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a . $out/
      runHook postInstall
    '';
  };

  prepareSdkTree = ''
    mkdir sdk
    cp -a ${preparedSdk}/. sdk/
    chmod -R u+w sdk
    rm -rf sdk/package/ziti-edge-tunnel
    cp -R ${packageTree} sdk/package/ziti-edge-tunnel
    cat >>sdk/.config <<'EOF'
CONFIG_PACKAGE_ziti-edge-tunnel=m
EOF
    make -C sdk defconfig
  '';

  downloadCache = pkgs.stdenvNoCC.mkDerivation {
    pname = "ziti-edge-tunnel-openwrt-download-cache";
    inherit version;
    nativeBuildInputs = nativeTools ++ [ pkgs.curl pkgs.wget ];
    dontUnpack = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = lib.fakeHash;

    buildPhase = ''
      runHook preBuild
      ${prepareSdkTree}
      make -C sdk download -j1 V=s
      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out
      cp -a sdk/dl/. $out/
    '';
  };

in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ziti-edge-tunnel-openwrt";
  inherit version;
  nativeBuildInputs = nativeTools;
  dontUnpack = true;
  strictDeps = true;

  buildPhase = ''
    runHook preBuild
    ${prepareSdkTree}
    mkdir -p sdk/dl
    cp -a ${downloadCache}/. sdk/dl/
    make -C sdk package/ziti-edge-tunnel/compile -j"$NIX_BUILD_CORES" V=sc
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    mapfile -t packages < <(
      find sdk/bin/packages sdk/bin/targets -type f \
        -name "ziti-edge-tunnel_${version}-*_mipsel_24kc.ipk" -print
    )
    if [ "''${#packages[@]}" -ne 1 ]; then
      printf 'expected exactly one ziti-edge-tunnel ipk, found %s\n' "''${#packages[@]}" >&2
      printf '%s\n' "''${packages[@]}" >&2
      exit 1
    fi
    cp "''${packages[0]}" $out/
    (cd $out && sha256sum *.ipk >SHA256SUMS)
    runHook postInstall
  '';

  meta = {
    description = "OpenZiti edge tunneler package for OpenWRT 24.10.3 ramips/mt7621";
    homepage = "https://openziti.io/";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
```

The `lib.fakeHash` value is intentional only for the next red step. It must not remain in the committed implementation.

- [ ] **Step 5: Stage new flake paths, then run the fixed-output hash probe**

Git-backed flakes omit untracked files, so stage the complete Task 2 paths before running the normal flake command:

```bash
git add \
  flake.nix \
  modules/packages/ziti-edge-tunnel-openwrt.nix \
  nix/packages/ziti-edge-tunnel-openwrt/default.nix \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/Makefile
set +e
nix build .#ziti-edge-tunnel-openwrt --print-build-logs 2>&1 | tee /tmp/ziti-openwrt-hash-probe.log
probe_status=${PIPESTATUS[0]}
set -e
[ "$probe_status" -ne 0 ]
actual_hash=$(
  sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*$/\1/p' \
    /tmp/ziti-openwrt-hash-probe.log | tail -1
)
[ -n "$actual_hash" ]
printf 'download cache hash: %s\n' "$actual_hash"
```

Expected: FAIL at the fixed-output download cache, followed by one printed recursive SRI hash. If `actual_hash` is empty, the build failed before the expected hash mismatch; stop and diagnose that earlier error before editing the hash.

- [ ] **Step 6: Replace the fake download-cache hash with the captured value**

Use the captured hash to replace the sentinel deterministically:

```bash
actual_hash=$(
  sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*$/\1/p' \
    /tmp/ziti-openwrt-hash-probe.log | tail -1
)
python3 - "$actual_hash" <<'PY'
from pathlib import Path
import sys

path = Path("nix/packages/ziti-edge-tunnel-openwrt/default.nix")
text = path.read_text()
old = "    outputHash = lib.fakeHash;"
new = f'    outputHash = "{sys.argv[1]}";'
if text.count(old) != 1:
    raise SystemExit("expected exactly one fake output hash")
path.write_text(text.replace(old, new))
PY
! rg -n 'fakeHash|fakeSha256' nix/packages/ziti-edge-tunnel-openwrt/default.nix
```

The captured SRI value comes from the fixed OpenWRT download closure and must not be guessed.

- [ ] **Step 7: Build the real package and rerun service behavior**

Run:

```bash
nix build .#ziti-edge-tunnel-openwrt --print-build-logs
bash nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel
ls -l result/*.ipk result/SHA256SUMS
```

Expected:

- `nix build` exits 0 without a network-access attempt in the final non-fixed-output derivation;
- the service harness reports seven passing cases;
- `result/` contains one `ziti-edge-tunnel_1.15.1-r1_mipsel_24kc.ipk` and `SHA256SUMS`.

If a target library is missing, add its OpenWRT package name to `DEPENDS`, rerun the fixed-output download-cache hash cycle, and verify the final binary dependency in Task 3. Do not link a NixOS library into the target binary.

- [ ] **Step 8: Commit the reproducible package builder**

```bash
git add flake.nix modules/packages/ziti-edge-tunnel-openwrt.nix nix/packages/ziti-edge-tunnel-openwrt
git diff --cached --check
git commit -m "feat(ziti): build OpenWRT tunnel package"
```

---

### Task 3: Validate the `.ipk` as an OpenWRT MIPS/musl Artifact

**Files:**
- Create: `nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh`
- Modify: `modules/packages/ziti-edge-tunnel-openwrt.nix`

**Interfaces:**
- Consumes: Task 2 package output directory.
- Produces: `checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk`.
- Script interface: `verify-ipk.sh IPK_PATH EXPECTED_ARCH EXPECTED_VERSION`.
- Accepted direct runtime dependencies: `ca-bundle`, `libatomic1`, `libjson-c5`, `libopenssl3`, `libpcap1`, `libprotobuf-c`, `libsodium`, `libstdcpp6`, `libuv1`, and `zlib`; libc/libgcc/pthread/rt/dl/m are supplied by the OpenWRT base runtime.

- [ ] **Step 1: Create a red validation invocation**

Before creating the validator, run:

```bash
bash nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh \
  result/ziti-edge-tunnel_1.15.1-r1_mipsel_24kc.ipk \
  mipsel_24kc \
  1.15.1
```

Expected: FAIL because `verify-ipk.sh` does not exist.

- [ ] **Step 2: Implement the package validator**

Create `nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ipk=${1:?usage: verify-ipk.sh IPK ARCH VERSION}
expected_arch=${2:?missing architecture}
expected_version=${3:?missing version}
[[ -f $ipk ]] || { printf 'missing ipk: %s\n' "$ipk" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

extract_member() {
  local member=$1 destination=$2
  mkdir -p "$destination"
  case "$member" in
    *.tar.gz) ar p "$ipk" "$member" | gzip -dc | tar -xf - -C "$destination" ;;
    *.tar.xz) ar p "$ipk" "$member" | xz -dc | tar -xf - -C "$destination" ;;
    *.tar.zst) ar p "$ipk" "$member" | zstd -dc | tar -xf - -C "$destination" ;;
    *) printf 'unsupported ipk member: %s\n' "$member" >&2; exit 1 ;;
  esac
}

control_member=$(ar t "$ipk" | grep -E '^control\.tar\.(gz|xz|zst)$')
data_member=$(ar t "$ipk" | grep -E '^data\.tar\.(gz|xz|zst)$')
[[ -n $control_member && -n $data_member ]] || { printf 'invalid ipk members\n' >&2; exit 1; }
extract_member "$control_member" "$tmp/control"
extract_member "$data_member" "$tmp/data"

control=$tmp/control/control
binary=$tmp/data/usr/bin/ziti-edge-tunnel
init=$tmp/data/etc/init.d/ziti-edge-tunnel
config=$tmp/data/etc/config/ziti-edge-tunnel
identity_dir=$tmp/data/etc/openziti/identities

for path in "$control" "$binary" "$init" "$config"; do
  [[ -f $path ]] || { printf 'missing package file: %s\n' "$path" >&2; exit 1; }
done
[[ -d $identity_dir ]] || { printf 'missing identity directory\n' >&2; exit 1; }

grep -Fx "Architecture: $expected_arch" "$control" >/dev/null
grep -E "^Version: ${expected_version}-r[0-9]+$" "$control" >/dev/null

depends=$(
  sed -n 's/^Depends: //p' "$control" | tr ',' '\n' | \
    sed -E 's/^[[:space:]]*//; s/[[:space:]]*\(.*\)$//'
)
has_dependency() {
  printf '%s\n' "$depends" | grep -Fx "$1" >/dev/null
}

for dependency in \
  ca-bundle libatomic1 libjson-c5 libopenssl3 libpcap1 libprotobuf-c \
  libsodium libstdcpp6 libuv1 zlib; do
  has_dependency "$dependency" || {
    printf 'missing declared dependency: %s\n' "$dependency" >&2
    exit 1
  }
done

[[ $(stat -c %a "$init") = 755 ]] || { printf 'init mode is not 0755\n' >&2; exit 1; }
[[ $(stat -c %a "$config") = 600 ]] || { printf 'config mode is not 0600\n' >&2; exit 1; }
[[ $(stat -c %a "$identity_dir") = 700 ]] || { printf 'identity directory mode is not 0700\n' >&2; exit 1; }

file "$binary" | grep -E 'ELF 32-bit LSB.*MIPS' >/dev/null
readelf -h "$binary" | grep -E 'Data:.*little endian' >/dev/null
readelf -h "$binary" | grep -E 'Machine:.*MIPS' >/dev/null
readelf -l "$binary" | grep -E 'Requesting program interpreter: /lib/ld-musl-mipsel[^]]*\.so\.1' >/dev/null

while read -r soname; do
  case "$soname" in
    libc.so|libgcc_s.so.1|libm.so*|libpthread.so*|librt.so*|libdl.so*) : ;;
    libatomic.so.1) has_dependency libatomic1 ;;
    libjson-c.so.5) has_dependency libjson-c5 ;;
    libssl.so.3|libcrypto.so.3) has_dependency libopenssl3 ;;
    libpcap.so*) has_dependency libpcap1 ;;
    libprotobuf-c.so*) has_dependency libprotobuf-c ;;
    libsodium.so*) has_dependency libsodium ;;
    libstdc++.so.6) has_dependency libstdcpp6 ;;
    libuv.so.1) has_dependency libuv1 ;;
    libz.so.1) has_dependency zlib ;;
    *) printf 'unmapped DT_NEEDED library: %s\n' "$soname" >&2; exit 1 ;;
  esac
 done < <(readelf -d "$binary" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')

printf 'verified %s: %s %s MIPS little-endian musl\n' "$ipk" "$expected_arch" "$expected_version"
```

- [ ] **Step 3: Run the validator directly against the real package**

Run:

```bash
chmod +x nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh
ipk=$(printf '%s\n' result/*.ipk)
bash nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh "$ipk" mipsel_24kc 1.15.1
```

Expected: one `verified ... MIPS little-endian musl` line and exit 0.

To confirm the validator rejects a malformed input, also run:

```bash
if bash nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh /dev/null mipsel_24kc 1.15.1; then
  printf 'validator accepted /dev/null\n' >&2
  exit 1
fi
```

Expected: nonzero exit.

- [ ] **Step 4: Add the validator to flake checks**

Extend the `let` block in `modules/packages/ziti-edge-tunnel-openwrt.nix`:

```nix
      verify-ipk = ../../nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh;
```

Add this check next to the build and service checks:

```nix
      checks.ziti-edge-tunnel-openwrt-ipk = pkgs.runCommand "ziti-edge-tunnel-openwrt-ipk-test" {
        nativeBuildInputs = [
          pkgs.binutils
          pkgs.file
          pkgs.gnutar
          pkgs.gzip
          pkgs.xz
          pkgs.zstd
        ];
      } ''
        ipk=$(printf '%s\n' ${ziti-edge-tunnel-openwrt}/*.ipk)
        bash ${verify-ipk} "$ipk" mipsel_24kc 1.15.1
        touch $out
      '';
```

- [ ] **Step 5: Run focused flake checks**

Stage the validator so the git-backed flake includes it, then run:

```bash
git add \
  modules/packages/ziti-edge-tunnel-openwrt.nix \
  nix/packages/ziti-edge-tunnel-openwrt/tests/verify-ipk.sh
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-service --print-build-logs
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk --print-build-logs
```

Expected: both checks exit 0. The IPK check must rebuild or reuse the exact Task 2 package derivation.

- [ ] **Step 6: Commit package verification**

```bash
git diff --cached --check
git commit -m "test(ziti): verify OpenWRT tunnel package"
```

---

### Task 4: Document Installation and Complete Verification

**Files:**
- Create: `docs/ziti-edge-tunnel-openwrt.md`

**Interfaces:**
- Consumes: Task 2 package output and Task 3 validation checks.
- Produces: operator commands for build, install, enrollment, logs, stop, uninstall, and router acceptance.
- Requires human-provided values only through shell variables: `ROUTER`, `JWT`, and `ZITI_SERVICE_URL`.

- [ ] **Step 1: Write the operator runbook**

Create `docs/ziti-edge-tunnel-openwrt.md` with these exact sections and commands:

~~~~markdown
# Ziti Edge Tunnel on ASUS RT-AX53U

This package targets OpenWRT 24.10.3 on `ramips/mt7621` (`mipsel_24kc`).
It gives processes running on the router access to Ziti services. It does not
route LAN clients through Ziti.

## Build

```sh
nix build .#ziti-edge-tunnel-openwrt
cat result/SHA256SUMS
```

## Copy and install

Set the router SSH destination and copy the package:

```sh
ROUTER=root@192.168.1.1
IPK=$(printf '%s\n' result/*.ipk)
scp "$IPK" "$ROUTER:/tmp/"
ssh "$ROUTER" 'opkg update && opkg install /tmp/ziti-edge-tunnel_*.ipk'
ssh "$ROUTER" 'ziti-edge-tunnel version'
```

## Enroll once

Copy a fresh enrollment JWT without storing it in this repository:

```sh
JWT=$HOME/Downloads/router.jwt
scp "$JWT" "$ROUTER:/etc/openziti/enroll.jwt"
ssh "$ROUTER" 'chmod 0600 /etc/openziti/enroll.jwt'
```

Enable and start the service:

```sh
ssh "$ROUTER" "uci set ziti-edge-tunnel.main.enabled='1'; \
  uci commit ziti-edge-tunnel; \
  /etc/init.d/ziti-edge-tunnel enable; \
  /etc/init.d/ziti-edge-tunnel start"
```

A successful enrollment creates
`/etc/openziti/identities/router.json` and removes
`/etc/openziti/enroll.jwt`.

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
~~~~

- [ ] **Step 2: Run all local verification from a clean staged tree**

Run:

```bash
git add docs/ziti-edge-tunnel-openwrt.md
nix fmt -- --check
bash nix/packages/ziti-edge-tunnel-openwrt/tests/service-test.sh \
  nix/packages/ziti-edge-tunnel-openwrt/openwrt/files/etc/init.d/ziti-edge-tunnel
nix build .#ziti-edge-tunnel-openwrt --print-build-logs
nix build .#checks.x86_64-linux.ziti-edge-tunnel-openwrt-ipk --print-build-logs
nix flake check --accept-flake-config --print-build-logs
git diff --check
git diff --cached --check
```

Expected:

- formatter exits 0;
- seven service tests pass;
- package and IPK validation builds exit 0;
- the full flake check reports `all checks passed`;
- both Git whitespace checks produce no output.

Documentation is static, so do not add a test that asserts its wording. The commands above directly verify the referenced package and service behavior.

- [ ] **Step 3: Commit the runbook**

```bash
git commit -m "docs(ziti): add OpenWRT installation runbook"
```

- [ ] **Step 4: Perform human-assisted router acceptance**

Follow `docs/ziti-edge-tunnel-openwrt.md` on the ASUS RT-AX53U and record these results in the task handoff:

```text
opkg install: pass/fail
ziti-edge-tunnel version: exact output
enrollment identity created: pass/fail
JWT removed after success: pass/fail
service survives reboot: pass/fail
router-local Ziti service request: pass/fail
ordinary router DNS during service: pass/fail
ordinary router DNS after stop: pass/fail
LAN client routing/DNS unchanged: pass/fail
```

Do not claim the on-router acceptance criteria have passed without the command output from the router. If router access is unavailable, report local build completion separately and leave on-router acceptance explicitly pending.

- [ ] **Step 5: Request adversarial code review before integration**

Request a fresh-context review with:

- design: `docs/specs/2026-08-15-ziti-edge-tunnel-openwrt-design.md`;
- plan: `docs/plans/2026-08-15-ziti-edge-tunnel-openwrt.md`;
- base SHA: `76dddf5b9c67ddf8de53f4d490904d4f62636490`;
- head SHA: the final implementation commit;
- focus: sandbox purity, target/host library separation, JWT deletion safety, resolver cleanup, package metadata, and verification evidence.

Apply valid feedback with the `receiving-code-review` workflow, rerun the full local verification, and present branch-completion options. If the user chooses local integration, offer a squash merge into `main` rather than a regular merge.
