# Firefox 1Password IndexedDB Reset Design

## Status

Approved for implementation.

## Problem

Home Manager installs the 1Password XPI in each managed Firefox profile. Reinstalling the XPI does not remove the extension's IndexedDB data.

Invalid IndexedDB data can prevent 1Password from starting. Firefox then shows an unknown database error, although the extension remains installed and enabled.

The recovery command must remove only the 1Password IndexedDB data. It must not remove other extension data or Firefox profile data.

## Decision

Add a repository-local Python script:

```text
scripts/reset-firefox-onepassword-indexeddb.py
```

Do not add a Pi skill. This operation is deterministic and project-specific. An executable script gives the same result for a person or an agent.

Use only the Python standard library. Add unit tests under `scripts/tests/`.

## Command Interface

The script supports these commands:

```bash
scripts/reset-firefox-onepassword-indexeddb.py --all
scripts/reset-firefox-onepassword-indexeddb.py --profile default --profile clubhouse
scripts/reset-firefox-onepassword-indexeddb.py --all --yes
```

`--profile NAME` is repeatable. The user must supply `--all` or one or more `--profile` arguments.

`--all` and `--profile` are mutually exclusive. The `--yes` option skips the confirmation prompt.

The script does not launch Firefox after the reset. The user starts Firefox and reconnects 1Password if necessary.

## Profile Discovery

Read Firefox profiles from:

```text
~/.mozilla/firefox/profiles.ini
```

Support relative and absolute profile paths from `profiles.ini`.

For each selected profile, read `prefs.js`. Parse the `extensions.webextensions.uuids` preference and get the UUID for this 1Password extension ID:

```text
{d634138d-c276-4fc8-924b-40a0ea21d284}
```

Build the reset path from the selected profile and the UUID:

```text
<profile>/storage/default/moz-extension+++<uuid>/idb
```

Do not depend on an IndexedDB file name. The file name can change between 1Password versions.

## Safety Rules

The script must complete all preflight checks before it removes data.

The preflight checks must:

1. Refuse to continue if Firefox is active.
2. Reject an unknown profile name.
3. Reject malformed or missing profile data.
4. Reject a profile without a registered 1Password UUID.
5. Reject a reset path that escapes the selected profile directory.
6. Reject a reset path that is a symbolic link.

Inspect Linux process data under `/proc` to find active `firefox` or `firefox-bin` processes. This avoids an extra command dependency.

Show each selected profile, reset path, and current data size. Then show one confirmation prompt that defaults to No.

If standard input is not interactive, require `--yes`. Treat an absent IndexedDB directory as a successful no-op.

Remove only the validated `idb` directory. Keep `storage.js`, local storage, the XPI, and all other profile data.

## Operation Flow

1. Parse the command arguments.
2. Make sure that Firefox is not active.
3. Read and select the Firefox profiles.
4. Resolve and validate every reset path.
5. Show the complete reset plan.
6. Ask for confirmation unless `--yes` is present.
7. Remove each existing IndexedDB directory.
8. Show one result line for each selected profile.
9. Tell the user to start Firefox and reconnect 1Password if necessary.

Do not remove any data if a preflight check fails.

## Results and Exit Codes

Use concise result labels:

- `RESET`: the script removed an IndexedDB directory.
- `SKIP`: the directory was already absent.
- `ERROR`: the script did not complete the operation.
- `CANCELLED`: the user declined the confirmation prompt.

Return exit code `0` after a successful reset, a successful no-op, or user cancellation. Return a nonzero exit code for argument, preflight, or removal errors.

Do not include IndexedDB contents in command output or error messages.

## Tests

Add unit tests for behavior that can cause a wrong or unsafe reset:

- Relative and absolute profile discovery.
- Repeated `--profile` selection.
- Mutual exclusion of `--all` and `--profile`.
- Parsing the nested JSON value in `prefs.js`.
- Rejection of unknown profiles and missing UUIDs.
- Refusal while Firefox is active.
- Rejection of paths outside the profile and symbolic-link targets.
- All-or-nothing preflight behavior.
- Confirmation, cancellation, and `--yes` behavior.
- Removal of only the selected IndexedDB directories.
- Successful handling of an absent directory.

Use temporary directories and synthetic profile data. Do not read or modify real Firefox profiles during unit tests.

## Verification

Run the script test suite:

```bash
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

Check the command interface:

```bash
python3 scripts/reset-firefox-onepassword-indexeddb.py --help
```

A live Firefox launch is not part of this script or its automated verification.
