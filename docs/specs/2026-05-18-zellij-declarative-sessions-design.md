# Zellij Declarative Sessions Design

## Goal

Provide a manual command that recreates a known set of Zellij sessions after reboot. The command should create every declared session in a known order, launch the declared panes and applications for each session, and then attach to the first declared session.

## Scope

This first version is intentionally manual. It does not install a `systemd.user` service or otherwise start sessions automatically at login. It assumes a clean slate after reboot, but handles an unexpectedly existing session by skipping creation rather than killing or replacing it.

## Approach

Use native Zellij KDL layout files for the session layouts, and use Nix/Home Manager only for installation and startup ordering.

The Home Manager Zellij module will define an ordered list of sessions, likely in a separate file such as `modules/home/desktop/shell/zellij/sessions.nix`:

```nix
[
  {
    name = "nixdots";
    layout = ./sessions/nixdots.kdl;
  }
  {
    name = "homelab";
    layout = ./sessions/homelab.kdl;
  }
]
```

The list order is the startup order. The first entry is also the session that the startup script attaches to after all declared sessions have been created or skipped.

## Layout files

Each session uses a hand-written Zellij KDL layout file. The KDL file is the source of truth for tabs, pane splits, pane names, working directories, and applications launched in panes.

Example shape:

```kdl
layout {
  tab name="nixdots" {
    pane cwd="/home/roche/nixdots" command="nvim"
    pane split_direction="vertical" {
      pane cwd="/home/roche/nixdots" command="lazygit"
      pane cwd="/home/roche/nixdots"
    }
  }
}
```

Home Manager installs each declared layout under the Zellij layout directory, for example `~/.config/zellij/layouts/sessions/nixdots.kdl`.

## Startup script

Home Manager generates a script, tentatively named `zellij-start-sessions`, and adds it to `home.packages`.

The script behavior is:

1. Read the ordered session list baked in by Nix.
2. For each declared session:
   - check `zellij list-sessions -n`;
   - if the session already exists, skip it;
   - otherwise create the session in the background using the declared KDL layout.
3. After all sessions are created or skipped, attach to the first declared session with `zellij attach <first-session>`.

If creating a session fails, the script exits with a clear error instead of continuing with a partially initialized environment.

## Integration with existing configuration

The existing Zellij configuration remains in `modules/home/desktop/shell/zellij/default.nix`. The current `roche-stacked` default layout and session shortcut plugin remain unchanged.

The new pieces are additive:

- a declarative ordered session manifest;
- one or more native KDL session layout files;
- a generated manual startup script.

## Alternatives considered

### One KDL file per session plus a separate ordered name list

This is simple and direct, but separates session names/order from layout paths. It is acceptable, but a structured Nix manifest makes the relationship explicit.

### Pure Nix definitions that generate KDL

This would make everything strongly declarative in Nix, but it would require maintaining a KDL renderer and would be less direct than writing native Zellij layouts.

### A single combined multi-session KDL file

Zellij layouts are designed for one session layout, not as a multi-session startup manifest. A script would still need separate metadata for names and startup order.

## Testing and verification

Verification should include:

- checking generated shell syntax where practical;
- validating or smoke-testing the declared Zellij layout files where practical;
- building the affected Home Manager activation package;
- reviewing the diff for unrelated changes or secrets.
