# PassFF Private Metadata Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a private host-only metadata index so PassFF URL matching works without `pass grep` decrypting the store at Firefox startup.

**Architecture:** Add `metadata_index.py` for parsing, reading/writing, synthetic grep output, and manual refresh. Route `grepMetaUrls` in the shared daemon to the index and package a `passff-shared-index` CLI. Re-enable PassFF `indexMetaUrls` because the daemon now answers it cheaply.

**Tech Stack:** Python standard library, pytest, Nix/Home Manager.

---

## Tasks

### Task 1: Metadata index module

- Create `modules/home/desktop/browser/firefox/passff-shared/metadata_index.py`.
- Create `tests/test_metadata_index.py`.
- Test extraction skips the first password line and indexes only configured URL fields.
- Test synthetic grep output matches PassFF's expected `entry:\nurl: value` shape.
- Test missing index returns empty successful response.

### Task 2: Daemon routing

- Modify `daemon.py` so default `grepMetaUrls` requests use `metadata_index.run_metadata_request` instead of `pass grep`.
- Keep existing broker single-flight/cache behavior.
- Add a daemon test proving `grepMetaUrls` does not invoke the pass runner.

### Task 3: CLI and package integration

- Add `passff-shared-index refresh` entrypoint via `metadata_index.py` or a small wrapper.
- Package `metadata_index.py` in `default.nix`.
- Add a wrapped `passff-shared-index` executable.
- Re-enable `indexMetaUrls` in `config/passff.json`.

### Task 4: Verification

- Run Python tests.
- Run Python syntax checks.
- Run `nix fmt` on touched Nix files.
- Build Home Manager activation package.
- Activate Home Manager.
- Verify `passff-shared-index refresh --help` works.
- Verify a missing index makes proxy `grepMetaUrls` return success quickly without `pass grep` processes.
