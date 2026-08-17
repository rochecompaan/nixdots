# OpenWRT Ziti r6 Resolver Design

**Status:** Approved.

## Context

The router has two resolver paths for `ha.compaan`.

- Ziti DNS at `100.64.0.2` returns the synthetic address `100.64.0.4`.
- dnsmasq at `127.0.0.1` returns the router address `192.168.1.1`.

The dnsmasq answer bypasses Ziti. It sends the request through local HAProxy and public Traefik. That path caused the intermittent default certificates.

The Ziti path returns the correct private certificate. This result excludes Kubernetes, the CA bundle, and Ziti terminators as root causes.

Package release r5 remains installed and passes its package checks. Its source commit is `8db9d5d0`, and its IPK SHA-256 is:

```text
004ed3d9d8265bc689cd7fd589decc2c572fe9d5ae3846d4143b21dc0b831cb2
```

Release r6 corrects only the resolver path. It keeps the r5 CA trust behavior.

## Goals

- Send `ha.compaan` queries from router processes only to Ziti DNS.
- Return NXDOMAIN locally for `.compaan` names outside the reserved `ha.compaan` subtree.
- Prevent those unknown private names from reaching public DNS.
- Keep public DNS queries on the existing dnsmasq and WAN resolver path.
- Keep the resolver rules when the Ziti service stops or becomes disabled.
- Preserve identical rules that an administrator created before r6.
- Restore a missing rule that the package owns.
- Remove only package-owned rules during final package removal.
- Fail tunnel startup when resolver preparation fails.
- Support safe retries after UCI or dnsmasq errors.

## Non-goals

- The package does not manage `/etc/hosts`.
- The package does not change HAProxy, Traefik, Home Assistant, or Kubernetes.
- The package does not change Ziti identities, policies, services, or terminators.
- The package does not route LAN client traffic through Ziti.
- The package does not change DHCP leases, ranges, client options, or firewall zones.
- The package does not replace dnsmasq or the WAN resolver configuration.
- The package does not call a production webhook.
- The package does not support forced removal that ignores maintainer-script errors.

## Selected resolver rules

Release r6 manages these dnsmasq server values through standard UCI:

```text
server=/compaan/
server=/ha.compaan/100.64.0.2
```

The UCI representation uses the `server` list on `dhcp.@dnsmasq[0]`:

```text
/compaan/
/ha.compaan/100.64.0.2
```

The broad rule has no upstream address. dnsmasq therefore answers unmatched `.compaan` names from local data or returns NXDOMAIN.

The more-specific rule sends `ha.compaan` to Ziti DNS. dnsmasq selects this rule before the broad `.compaan` rule.

### Query behavior

| Query | dnsmasq action | Result |
| --- | --- | --- |
| `ha.compaan` | Send only to `100.64.0.2` | Ziti returns `100.64.0.4` |
| Another `.compaan` name outside `ha.compaan` | Use the local-only guard | Local data or NXDOMAIN |
| A public name | Use the existing general resolvers | Existing WAN DNS result |

If Ziti DNS is unavailable, `ha.compaan` fails closed. dnsmasq does not send that query to a public resolver.

### dnsmasq match scope

A dnsmasq `server=/domain/` rule matches the named domain and its descendants. Therefore, the selected forward also sends `child.ha.compaan` to Ziti DNS.

This design reserves the `ha.compaan` subtree for Ziti. The local NXDOMAIN guarantee applies to names outside that reserved subtree, such as `unknown.compaan`.

A descendant that Ziti does not know can still recurse through `127.0.0.1`. No current service or client uses a descendant of `ha.compaan`.

If the NXDOMAIN guarantee must include those descendants, the two approved rules need revision before implementation planning.

The rules remain in dnsmasq when Ziti stops. The same rule persistence applies when the Ziti service becomes disabled.

Rule repair is event-driven. It occurs during live package installation and each init-script start attempt. No background process monitors UCI.

## Recursion prevention

A suffix-wide Ziti forward is unsafe:

```text
dnsmasq -> Ziti DNS -> dns_upstream 127.0.0.1 -> dnsmasq
```

Ziti forwards unknown names to its configured upstream. A suffix-wide forward can therefore send an unknown private name around this loop.

The local-only `.compaan` guard stops unknown private names outside the reserved subtree. The more-specific rule keeps the reserved `ha.compaan` subtree on Ziti DNS.

## Preserved tunnel behavior

The procd command remains:

```text
/usr/lib/ziti-edge-tunnel/run-managed
```

The tunnel keeps this argument:

```text
--dns-upstream 127.0.0.1
```

Public names that reach Ziti continue to use dnsmasq as the upstream. The tunnel remains limited to router-originated traffic.

## Rejected approaches

### Suffix-wide Ziti forwarding

A single `server=/compaan/100.64.0.2` rule is rejected. Unknown private names can recurse between dnsmasq and Ziti DNS.

### Static address or hosts entry

A static `100.64.0.4` mapping is rejected. Ziti owns synthetic address allocation, and static name resolution bypasses Ziti DNS behavior.

An `/etc/hosts` entry is also rejected. The package must not manage `/etc/hosts`.

### Service-scoped rules

Adding rules only during Ziti startup is rejected. The rules must survive service stop and disable operations.

Removing rules during service stop is also rejected. That behavior can restore the unsafe public path.

## Package release and files

The package version remains `1.15.1`. The OpenWRT package release changes from r5 to r6.

Add `dnsmasq` to the OpenWRT package dependencies. Keep all current dependencies.

Install this new file:

- `/usr/lib/ziti-edge-tunnel/update-dnsmasq`, root-owned, mode `0755`

Keep these existing package files and behaviors:

- `/usr/lib/ziti-edge-tunnel/run-managed`
- `/usr/lib/ziti-edge-tunnel/update-ca-bundle`
- `/etc/ssl/certs/compaan-ca.crt`
- `/etc/init.d/ziti-edge-tunnel`
- `/etc/config/ziti-edge-tunnel`

The repository keeps the CA source only at `modules/nixos/core/certs/compaan-ca.crt`. The Nix build can copy it into the generated OpenWRT package tree.

## Ownership state

The package tracks each dnsmasq rule separately in `/etc/config/ziti-edge-tunnel`.

The `main` section gains these options:

```text
option dnsmasq_compaan_guard_owned '0'
option dnsmasq_ha_forward_owned '0'
```

A missing option has the same meaning as `0`. This default supports upgrades from r5 because OpenWRT preserves the existing conffile.

The helper accepts only `0` or `1` for an existing ownership option. Any other value causes a safe error before a dnsmasq change.

### Ownership rules

For each exact server value, `ensure` applies these rules:

1. If the rule exists and its flag is `0`, preserve it as external.
2. If the rule is absent and its flag is `0`, claim ownership and add it.
3. If the rule exists and its flag is `1`, leave it unchanged.
4. If the rule is absent and its flag is `1`, restore it.

The two flags support mixed ownership. One rule can remain external while the package owns the other rule.

The helper does not add a duplicate exact value. If an external exact value exists before the first `ensure`, the helper never claims it.

UCI list values do not contain per-item owner metadata. Administrators must not add a duplicate of a rule after the package owns that value.

For each rule, `remove` applies these rules:

1. If its flag is `0`, leave the rule unchanged.
2. If its flag is `1`, remove the exact value when present.
3. Clear the flag after successful removal or after detection that the owned rule is already absent.

## Helper interface

The new helper supports two actions:

```text
update-dnsmasq ensure
update-dnsmasq remove
```

An unknown action returns exit status `2`. Operational errors return a nonzero status and a short diagnostic on standard error.

Production uses these fixed resources:

- dnsmasq UCI section: `dhcp.@dnsmasq[0]`
- package UCI section: `ziti-edge-tunnel.main`
- dnsmasq init script: `/etc/init.d/dnsmasq`
- lock file: `/tmp/lock/ziti-edge-tunnel-dnsmasq.lock`
- expected lock owner: user ID `0`

Tests can use these environment overrides:

- `ZITI_DNSMASQ_UCI`, with production default `uci`
- `ZITI_DNSMASQ_INIT`, with production default `/etc/init.d/dnsmasq`
- `ZITI_DNSMASQ_LOCK`, with the production lock path
- `ZITI_DNSMASQ_LOCK_OWNER`, with production default `0`

Package scripts do not set these overrides.

The helper calls the dnsmasq init script with `reload`. It never stops or restarts dnsmasq.

The helper never calls the Ziti init script. It never stops or restarts Ziti.

## Secure lock behavior

The helper serializes `ensure` and `remove` with file descriptor `9`. Its lock checks match the CA helper checks.

Before lock acquisition, the helper does these checks:

1. Validate that the expected owner is numeric.
2. Create the lock parent directory when necessary.
3. Reject an existing lock path that is not a regular file.
4. Reject a symbolic link at the lock path.
5. Set `umask 077` and open the lock with append mode.
6. Inspect `/proc/self/fd/9` and the lock path.
7. Require owner `0` in production for both views.
8. Require mode `0600` for both views.
9. Require the path inode to equal the file-descriptor inode.
10. Acquire the lock with `flock`.

A failed check stops the helper before any UCI command. Tests cover owner, mode, symlink, inode-replacement, and invalid-path regressions.

This lock is separate from the procd service lock and the CA bundle lock. The helper holds only its own lock during UCI work and dnsmasq reloads.

## UCI mutation and recovery

The helper reads both exact server values and both ownership flags before a mutation. It changes only those four values.

### Ensure order

For a new package-owned rule, the helper commits its ownership flag before it commits the dnsmasq rule. This order makes an interrupted operation recoverable.

If the ownership commit succeeds and the dnsmasq commit fails, the flag remains `1`. A later `ensure` restores the missing owned rule.

The helper reverts uncommitted UCI deltas after a command error. It returns nonzero and does not reload dnsmasq when no dnsmasq commit occurred.

### Remove order

The helper commits removal of owned dnsmasq rules before it clears their ownership flags. It reloads dnsmasq after the rule commit.

After a successful reload, the helper clears the ownership flags. If that commit fails, the flags remain `1` and a later `remove` completes the cleanup.

### Reload failure

The helper reloads dnsmasq once after one or more committed rule changes. It does not reload after an ownership-only change.

If reload fails, the helper restores the prior dnsmasq rule state. It commits that rollback and makes one best-effort reload of the restored state.

The helper keeps ownership flags conservative after a reload error. A newly claimed flag stays `1` after an `ensure` rollback.

An existing owned flag stays `1` after a `remove` rollback. A later call can retry without losing package ownership.

The helper returns nonzero after every reload error. A rollback error also returns nonzero and includes a separate diagnostic.

### Idempotence

If rules and ownership already match the requested state, the helper changes nothing. It does not commit UCI and does not reload dnsmasq.

## Package lifecycle

### New installation and r5 upgrade

The package `postinst` hook calls `update-dnsmasq ensure` on a live router. The existing CA bundle `ensure` action remains in the hook.

The hook returns nonzero when either helper fails. An offline installation with `IPKG_INSTROOT` set performs no live router mutation.

On an r5 upgrade, the ownership options are initially absent. The helper preserves any external exact rules and owns only missing rules.

### Service startup

The init script calls `update-dnsmasq ensure` immediately after it loads the Ziti configuration. This call occurs before the enabled check and procd registration.

An `ensure` error stops the start attempt. The init script does not call `procd_open_instance` after that error.

The existing CA refresh remains after the enabled check and before procd registration. Enrollment validation, resolver snapshots, and the managed command keep their behavior.

### Service stop and disable

The stop path does not call `update-dnsmasq remove`. Disabling the service does not call `remove` either.

As a result, private names cannot fall back to public DNS when Ziti is unavailable. `ha.compaan` can time out until Ziti DNS returns.

### Package upgrade

When `PKG_UPGRADE=1`, the package `prerm` hook does not remove dnsmasq rules or clear ownership flags. The incoming r6-or-newer package runs `ensure` from `postinst`.

The rules remain active across the package transition. The custom hooks do not stop or restart Ziti while they hold the dnsmasq lock.

OpenWRT default lifecycle code remains responsible for normal service stop and start operations. Those operations occur outside the helper process.

### Final package removal

When `PKG_UPGRADE` is not `1`, the package `prerm` hook calls `update-dnsmasq remove`. The hook returns nonzero if cleanup fails.

The helper removes only rules with ownership flag `1`. It preserves identical external rules with ownership flag `0`.

The existing CA bundle removal remains in the final-removal path. The package removes helper files only after the `prerm` hook completes.

## Rollback behavior

A failed `ensure` leaves either the prior rules or conservative ownership state. Running `ensure` again repairs any missing owned rule.

A failed final removal leaves the package installed because `prerm` returns nonzero. Running removal again retries owned-rule cleanup.

The supported rollback to r5 has two steps:

1. Remove r6 as a final package removal.
2. Install the known r5 IPK.

This sequence removes r6-owned resolver rules before r5 replaces the helper. A direct forced downgrade to r5 is outside this design because r5 cannot remove r6 ownership state.

External resolver rules survive the supported rollback. The r5 CA trust and tunnel behavior remain unchanged after the rollback.

## Error behavior

| Error | Required result |
| --- | --- |
| Invalid action | Exit `2` without UCI access |
| Unsafe lock | Exit nonzero without UCI access |
| Missing dnsmasq UCI section | Exit nonzero without reload |
| Invalid ownership flag | Exit nonzero without dnsmasq mutation |
| UCI read or write error | Exit nonzero and revert uncommitted deltas |
| Ownership commit error during `ensure` | Exit nonzero without dnsmasq mutation |
| dnsmasq commit error during `ensure` | Keep conservative ownership and exit nonzero |
| dnsmasq reload error | Restore prior rules, attempt rollback reload, and exit nonzero |
| Ownership clear error during `remove` | Keep conservative ownership and exit nonzero |
| Service preparation error | Do not register a procd instance |
| Unchanged state | Exit zero without commit or reload |

## Automated tests

### Helper tests

Create a focused Bash harness for `update-dnsmasq`. Run the helper under Bash and BusyBox ash.

The harness uses mock UCI and init commands. It covers these behaviors:

- add both missing rules
- repeat `ensure` without changes
- set separate ownership flags
- restore a missing owned guard
- restore a missing owned forward
- preserve both pre-existing external rules
- preserve one external rule while owning the other
- remove only package-owned rules
- preserve rules during `PKG_UPGRADE=1`
- clean owned rules during final removal
- fail safely on UCI read, write, and commit errors
- recover from partial ownership and rule commits
- fail safely on dnsmasq reload errors
- restore prior rules after a reload error
- reject insecure lock files and lock-path races
- avoid dnsmasq reload when the state is unchanged
- run the same helper cases under Bash and BusyBox ash

### Real dnsmasq routing test

Create `nix/packages/ziti-edge-tunnel-openwrt/tests/dnsmasq-test.sh`. Use a real host dnsmasq process on temporary high ports.

Start separate Ziti and public DNS stubs. Each stub records received query names and returns deterministic test answers.

Configure dnsmasq with the two selected rules and one general public upstream. Then prove these results:

1. `ha.compaan` reaches the Ziti stub and receives its synthetic answer.
2. An unknown sibling such as `unknown.compaan` returns NXDOMAIN.
3. The unknown private name never reaches the public stub.
4. A public name reaches the public stub and receives its answer.

The test uses only loopback addresses and temporary files. It does not contact the router, Ziti production services, or a webhook.

### Service tests

Extend `service-test.sh` with a mock dnsmasq helper. Prove that resolver preparation occurs before procd registration.

Also prove these cases:

- a successful call uses the `ensure` action
- a helper error prevents `procd_open_instance`
- CA preparation and existing enrollment behavior remain intact
- a disabled-service start attempt still repairs owned rules
- the init script does not remove dnsmasq rules during stop
- the service tests pass under Bash and BusyBox ash

### IPK and lifecycle checks

Extend `verify-ipk.sh` and its validator coverage. Verify these package properties:

- version `1.15.1-r6`
- dependency on `dnsmasq`
- root ownership for every archive member
- mode `0755` for `update-dnsmasq`
- the helper exists at the exact package path
- `postinst` calls `ensure`
- upgrade `prerm` preserves resolver rules
- final-removal `prerm` calls `remove`
- the exact expected control and data archive contents
- current CA helper, certificate, service, wrapper, and configuration files remain present

### Direct verification

Use direct commands for static release values, dependency text, file modes, and documentation. Do not add tests that only restate static Nix or Makefile text.

Run the focused helper, routing, service, and IPK checks. Then run the full flake check before release completion.

## Documentation

Update `docs/ziti-edge-tunnel-openwrt.md` during implementation. Document the r6 resolver rules, fail-closed behavior, ownership, lifecycle, and supported rollback.

Do not include JWTs, identities, credentials, private keys, or webhook paths. Do not call production systems during documentation verification.

## Acceptance criteria

The r6 design is complete when implementation verification proves all of these statements:

- Router `ha.compaan` queries use Ziti DNS at `100.64.0.2`.
- `.compaan` names outside the reserved `ha.compaan` subtree return local data or NXDOMAIN.
- Those unknown private names never reach public DNS.
- Public names keep their existing WAN resolver path.
- Resolver rules survive Ziti stop, disable, and package upgrade operations.
- The helper preserves identical pre-existing external rules.
- The helper restores missing package-owned rules.
- Final package removal removes only package-owned rules.
- Startup fails before procd registration when resolver preparation fails.
- Unchanged state causes no UCI commit and no dnsmasq reload.
- All helper cases pass under Bash and BusyBox ash.
- The real dnsmasq routing test proves query destinations.
- The r6 IPK has the required dependency, files, modes, ownership, hooks, and exact contents.
- No production webhook or private credential is used.
