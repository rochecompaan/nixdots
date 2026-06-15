# PassFF Private Metadata Index Design

## Problem

PassFF URL metadata indexing currently calls `grepMetaUrls`, which upstream implements as `pass grep`. That decrypts many password-store entries. With a YubiKey-backed GPG key and many Firefox profiles, startup can trigger long decrypt scans and pinentry contention.

## Goal

Keep PassFF URL metadata matching without decrypting the whole password store at Firefox startup.

## Design

The shared PassFF daemon answers `grepMetaUrls` from a private host-only metadata index instead of running `pass grep`.

- Index path defaults to `~/.cache/passff-shared/metadata-index.json`.
- Index file mode is `0600`.
- The index stores pass entry paths and configured URL metadata fields (`url`, `http`, `https`).
- It does not store password contents, OTP secrets, notes, or full decrypted entry contents.
- If the index is missing, `grepMetaUrls` returns an empty successful result rather than scanning the store.
- A new CLI, `passff-shared-index refresh`, refreshes the index manually by decrypting entries one at a time.

## Data format

```json
{
  "version": 1,
  "entries": [
    {
      "path": "private/login/example.com-user",
      "fields": {
        "url": ["https://example.com"]
      },
      "mtime": 1718460000
    }
  ]
}
```

## PassFF compatibility

For `grepMetaUrls`, the daemon emits synthetic `pass grep`-compatible stdout:

```text
private/login/example.com-user:
url: https://example.com
```

PassFF already parses this format after stripping ANSI escape codes.

## Update behavior

Initial implementation uses manual refresh only:

```sh
passff-shared-index refresh
```

Later work may add a timer or inotify-based refresh, but not in this change.

## Security model

The index is private to the local user account and stored with mode `0600`. It intentionally keeps selected URL metadata plaintext on the host. Secret contents remain encrypted in `pass` and are decrypted only on selected-entry access.
