# Zellij Session Shortcuts Design

## Goal

Provide mutable numbered Zellij session shortcuts. `Ctrl+1` through `Ctrl+9` switch to saved targets; `Ctrl+Shift+1` through `Ctrl+Shift+9` save the current session, active tab, focused pane, and pane cwd into the matching slot.

## Approach

Use a small preloaded Zellij plugin instead of `Run` helpers. Keybinds send `MessagePlugin` pipe messages to the plugin, which avoids creating or focusing a helper pane while saving. Slot data is stored in a mutable TSV file outside the Nix store, so changing shortcuts does not require `home-manager switch`.

## Data format

`~/.config/zellij/session-shortcuts.tsv` stores one target per line:

```tsv
# slot	session	cwd	tab_position	pane_id	is_plugin
1	nixdots	/home/roche/nixdots	0	16	false
```

The plugin accepts both numeric pane IDs plus `is_plugin`, and string pane IDs such as `terminal_16` or `plugin_2` when parsing manually-edited files.

## Behavior

- `switch` message with payload `N`: read slot `N` and switch to the target session. If cwd is present, switch with cwd first. If tab or pane is present, focus it after switching.
- `save` message with payload `N`: inspect current session state, find the active tab and focused pane in that tab, query the pane cwd, and upsert slot `N` in the TSV file.
- Missing or invalid slots are ignored safely and logged to stderr.
- Saving requires the plugin to be preloaded; keybinds use `MessagePlugin`, not `Run`, so the focused pane remains the intended pane.

## Nix integration

Home Manager builds the plugin to `~/.config/zellij/plugins/session-shortcuts.wasm`, defines a `session-shortcuts` plugin alias with the TSV path, preloads the alias, and adds the fixed switch/save keybindings.
