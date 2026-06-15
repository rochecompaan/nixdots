# Shared PassFF Daemon Design

## Problem

Niri starts multiple Firefox profiles at login. Each profile has PassFF installed, and PassFF launches its native messaging host independently. With URL metadata indexing and autofill enabled, the profiles can start many concurrent `pass` lookups. Because this password store decrypts through GPG/scdaemon/YubiKey, those concurrent lookups contend for one smartcard PIN flow, causing repeated pinentry prompts and slow or cancelled decrypts.

## Goals

- Keep all Firefox profiles launching at niri startup.
- Allow all profiles to use PassFF without concurrent GPG/pinentry storms.
- Share one per-user PassFF backend across profiles.
- Serialize `pass`/GPG operations so only one smartcard operation runs at a time.
- Coalesce duplicate in-flight metadata scans.
- Cache only non-secret metadata scan responses for a short TTL.
- Never cache decrypted password, OTP, insert, or generated secret responses.

## Non-goals

- Replacing PassFF's browser extension.
- Changing the password-store layout.
- Storing secrets outside `pass`.
- Persisting any daemon cache across login sessions.
- Removing Firefox profile autostart.

## Current context

`modules/home/desktop/wayland/niri/config/firefox-profiles.sh` launches the required Firefox profiles. `modules/home/desktop/browser/firefox/default.nix` installs PassFF and a patched `passff-host` for every shared Firefox profile. The current upstream/native host process is one-shot: it reads one native messaging request, runs `pass`, writes one response, and exits.

The observed process list showed many simultaneous PassFF native hosts and `pass` grep/show operations. The GPG journal showed repeated smartcard PIN callbacks and cancelled pinentry calls. This indicates contention among independent PassFF hosts rather than one intentionally shared backend.

## Proposed architecture

Introduce two local executables:

1. `passff-shared-daemon`
   - A per-user daemon listening on `$XDG_RUNTIME_DIR/passff-shared.sock`.
   - Accepts one JSON request per connection.
   - Executes PassFF-compatible `pass` operations.
   - Uses a process-local async lock or worker queue so only one `pass` command runs at a time.
   - Maintains a short-lived in-memory cache only for successful `grepMetaUrls` responses.
   - Coalesces concurrent identical `grepMetaUrls` requests so one scan serves all waiting clients.

2. `passff-shared-proxy`
   - The Firefox native messaging host command.
   - Reads one native messaging request from stdin.
   - Ensures the daemon is available, either by connecting to a systemd user socket or by starting it on demand.
   - Forwards the request to the daemon over the Unix socket.
   - Returns the daemon response using normal Firefox native messaging framing.

Firefox profiles keep using PassFF normally; only the native messaging host command changes from the upstream one-shot host to the proxy.

## Request handling

The daemon supports the same request shapes currently handled by `passff.py`:

- Empty request: list/show root.
- `grepMetaUrls`: search URL metadata fields.
- `show`: default request for an entry.
- `otp`: run `pass otp` for an entry.
- `insert`: insert multiline content.
- `generate`: generate a new password.

All responses preserve the current PassFF native host response shape:

```json
{
  "exitCode": 0,
  "stdout": "...",
  "stderr": "...",
  "version": "1.2.5"
}
```

For `grepMetaUrls`, successful responses may have `stderr` cleared as the upstream host already does, to avoid large native messages.

## Concurrency model

- All secret-affecting operations run through one serialized worker queue.
- `grepMetaUrls` requests use single-flight behavior keyed by the normalized URL field names.
- If an identical metadata scan is already running, later clients wait for the same result instead of starting another `pass grep`.
- A successful metadata scan is cached for a short TTL, initially 60 seconds.
- Cache entries live only in memory under `$XDG_RUNTIME_DIR` session lifetime.
- `show`, `otp`, `insert`, and `generate` are never cached.

This prevents many Firefox profiles from simultaneously invoking GPG while preserving current PassFF behavior.

## Systemd and startup

Prefer a systemd user socket:

- `passff-shared.socket` listens on `%t/passff-shared.sock`.
- `passff-shared.service` starts the daemon on first proxy connection.
- The proxy can also fall back to spawning the daemon if socket activation is unavailable, but the Nix/Home Manager path should use the socket.

Socket activation avoids starting the daemon unless PassFF is used and gives all profiles one rendezvous point.

## Nix/Home Manager integration

- Package local daemon/proxy scripts as Nix derivations.
- Override `passff-host` or provide a replacement native messaging host manifest whose `path` points at `passff-shared-proxy`.
- Keep the existing patched `pass` command with `pass-otp` support.
- Add a Home Manager user socket/service for the shared daemon.
- Keep existing PassFF extension settings, but consider a later separate change to reduce eager metadata indexing if needed.

## Error handling

- If the daemon cannot start or connect, the proxy returns a PassFF-shaped error response instead of hanging.
- Each daemon request has a timeout larger than normal smartcard latency, initially 60 seconds.
- If a client disconnects while waiting, the daemon should not cancel an already running `pass` command unless no other client needs the same single-flight result.
- The daemon logs concise request type, duration, exit code, and cache/single-flight status. It must not log decrypted secret output.

## Security considerations

- The socket lives in `$XDG_RUNTIME_DIR`, which is per-user and mode-restricted.
- The daemon must reject connections if the socket path or runtime directory permissions are unsafe.
- No decrypted `show` or `otp` output is cached.
- Logs must avoid password contents and full command stdout.
- Metadata cache may contain URL field matches from the password store, so it remains per-session memory only and never persists to disk.

## Testing and verification

Automated tests are valuable for the daemon/proxy protocol because they cover reusable logic:

- Native message framing encode/decode.
- Request translation compatibility with current `passff.py` behavior.
- Serialization of secret operations.
- Single-flight behavior for duplicate `grepMetaUrls` requests.
- TTL expiry for metadata cache.
- Error response when daemon is unavailable.

Manual verification should cover the system integration:

- Launch all niri Firefox profiles.
- Confirm there is one shared daemon and no burst of independent `passff-host`/`pass` processes.
- Confirm one `pass show` remains responsive while profiles are open.
- Confirm PassFF can fill a password from at least two different Firefox profiles.
- Confirm no repeated pinentry prompts appear during startup.

## Rollout plan

1. Implement daemon and proxy in small local scripts.
2. Add focused tests for protocol and concurrency behavior.
3. Package them through Nix/Home Manager.
4. Switch the PassFF native messaging host to the proxy.
5. Verify with all niri-launched Firefox profiles.
6. Keep the previous direct host derivation available during development so rollback is a one-line native host path change.
