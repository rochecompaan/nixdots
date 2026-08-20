# Manual Niri Firefox Profiles Command Design

## Context

The Niri module builds `niri-firefox-profiles` with `pkgs.writeShellApplication`. The wrapper adds `niri-firefox-launcher` to its private `PATH`.

Niri uses the wrapper during session startup. The wrapper is not in `home.packages`, so an interactive shell cannot find it.

The source file `firefox-profiles.sh` is executable. However, direct execution fails because the source file does not receive the wrapper's private `PATH`.

A long-running shell can also contain an old `NIRI_SOCKET` value. The observed old value named a socket path that no longer existed.

## Goals

- Add `niri-firefox-profiles` to the interactive user `PATH`.
- Keep the current Niri startup command unchanged.
- Keep a valid `NIRI_SOCKET` value unchanged.
- Recover when `NIRI_SOCKET` is unset or does not name a Unix socket.
- Do not select a socket when the correct choice is ambiguous.

## Non-goals

- Do not expose the low-level `niri-firefox-launcher` command in `home.packages`.
- Do not change Firefox profile assignments or workspace assignments.
- Do not change the Go launcher.
- Do not select between multiple active Niri sessions.
- Do not detect an unresponsive server when its Unix socket file still exists.

## Design

### Command installation

Add `firefoxProfiles` to `home.packages` in `config/autostart.nix`. The command name remains `niri-firefox-profiles`.

Keep the existing `spawn-at-startup` entry. It will continue to use the store path of the same package.

### Socket selection

Add socket selection to `firefox-profiles.sh` before the startup delay.

1. Use `NIRI_SOCKET` when it names a Unix socket.
2. Otherwise, get the runtime directory from `XDG_RUNTIME_DIR`.
3. If `XDG_RUNTIME_DIR` is unset, use `/run/user/$UID`.
4. Find Unix sockets that match `niri.*.sock` in the runtime directory.
5. If one socket exists, export its path as `NIRI_SOCKET`.
6. If no socket exists, show an error and stop.
7. If multiple sockets exist, show an error, list the candidates, and stop.

The script will use Bash glob expansion and `[[ -S path ]]`. It will not add an external runtime dependency.

### Launch sequence

After socket selection, keep the existing launch sequence unchanged. The script will start each profile through `niri-firefox-launcher` and focus workspace 2.

## Error handling

The script will write socket-selection errors to standard error. Each error will state the runtime directory and the corrective action.

The script will return a nonzero status when it cannot select one socket. It will not start a partial set of Firefox profiles in this case.

## Tests

Extend `firefox-profiles_test.sh` before the implementation change.

The shell tests will cover these cases:

- A valid `NIRI_SOCKET` remains unchanged.
- An unset value uses the only socket in `XDG_RUNTIME_DIR`.
- A stale value uses the only socket in `XDG_RUNTIME_DIR`.
- No socket produces a nonzero status and a clear error.
- Multiple sockets produce a nonzero status and a clear error.
- The existing profile launch order and workspace arguments remain unchanged.

The test will create temporary Unix socket files. It will use a small Python helper because a regular file does not satisfy Bash `-S` checks.

## Nix verification

Build the affected Home Manager activation package. Make sure that its `home-path/bin` directory contains `niri-firefox-profiles`.

Activate the profile after the build succeeds. Make sure that `command -v niri-firefox-profiles` returns the Home Manager profile path.

## Risks

A user can run more than one Niri session. Automatic selection is unsafe when more than one candidate exists. The command will stop and list the candidates in this case.

A dead server can leave a Unix socket file. This change does not detect that case. The low-level launcher will return the existing Niri connection error.
