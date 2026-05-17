# Zellij Session Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add mutable numbered Zellij session shortcuts with save and switch keybindings.

**Architecture:** A Rust Zellij plugin handles `MessagePlugin` pipe messages and persists slots to a TSV file. Home Manager builds and installs the plugin, preloads it, and adds fixed keybindings for slots 1-9.

**Tech Stack:** Rust, zellij-tile 0.44.1, Nix/Home Manager, Zellij KDL config.

---

### Task 1: Plugin domain logic

**Files:**
- Create: `modules/home/desktop/shell/zellij/session-shortcuts/Cargo.toml`
- Create: `modules/home/desktop/shell/zellij/session-shortcuts/src/shortcuts.rs`
- Create: `modules/home/desktop/shell/zellij/session-shortcuts/src/lib.rs`

- [x] Write failing Rust unit tests for TSV parsing, serialization, and slot upsert.
- [x] Run `cargo test` in the plugin directory and verify tests fail because the module is missing.
- [x] Implement the minimal pure TSV logic.
- [x] Run `cargo test --lib` and verify tests pass.

### Task 2: Zellij plugin shell

**Files:**
- Create: `modules/home/desktop/shell/zellij/session-shortcuts/src/main.rs`
- Modify: `modules/home/desktop/shell/zellij/session-shortcuts/src/lib.rs`

- [x] Add tests for pipe message parsing and focused-target selection.
- [x] Run `cargo test --lib` and verify tests fail before implementation.
- [x] Implement `ZellijPlugin` load/update/pipe handlers using `ModeUpdate`, `TabUpdate`, `PaneUpdate`, `get_pane_cwd`, `switch_session_with_cwd`, and `switch_session_with_focus`.
- [x] Run `cargo test --lib` and verify tests pass.

### Task 3: Nix packaging and Zellij config

**Files:**
- Create: `modules/home/desktop/shell/zellij/plugins.nix`
- Modify: `modules/home/desktop/shell/zellij/default.nix`

- [x] Add a Nix derivation that builds `session-shortcuts.wasm` for `wasm32-wasip1`.
- [x] Install the wasm under `xdg.configFile."zellij/plugins/session-shortcuts.wasm"`.
- [x] Add a `session-shortcuts` plugin alias, preload it, and bind `Ctrl 1`..`Ctrl 9` plus `Ctrl Shift 1`..`Ctrl Shift 9`.
- [x] Run Zellij config validation and Home Manager build/eval.

### Task 4: Verification

**Files:**
- Verify all files touched above.

- [x] Run plugin tests.
- [x] Run Nix/Home Manager evaluation for affected profiles.
- [x] Check `git diff` for secrets or unrelated changes.
