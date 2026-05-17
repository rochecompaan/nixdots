use std::collections::BTreeMap;
use std::path::PathBuf;

use zellij_session_shortcuts::plugin_logic::{
    focused_target, parse_pipe_command, PaneSnapshot, PipeCommand, TabSnapshot,
};
use zellij_session_shortcuts::shortcuts::{PaneTarget, ShortcutFile};
use zellij_tile::prelude::*;

#[derive(Default)]
struct SessionShortcutsPlugin {
    shortcut_file: PathBuf,
    session_name: Option<String>,
    tabs: Vec<TabSnapshot>,
    panes: Vec<PaneSnapshot>,
}

impl ZellijPlugin for SessionShortcutsPlugin {
    fn load(&mut self, configuration: BTreeMap<String, String>) {
        self.shortcut_file = configuration
            .get("shortcut_file")
            .map(PathBuf::from)
            .unwrap_or_else(default_shortcut_file);

        set_selectable(false);
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
            PermissionType::FullHdAccess,
        ]);
        subscribe(&[
            EventType::ModeUpdate,
            EventType::TabUpdate,
            EventType::PaneUpdate,
        ]);
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::ModeUpdate(mode_info) => {
                self.session_name = mode_info.session_name;
            },
            Event::TabUpdate(tabs) => {
                self.tabs = tabs
                    .into_iter()
                    .map(|tab| TabSnapshot {
                        position: tab.position,
                        active: tab.active,
                    })
                    .collect();
            },
            Event::PaneUpdate(pane_manifest) => {
                self.panes = pane_manifest
                    .panes
                    .into_iter()
                    .flat_map(|(tab_position, panes)| {
                        panes.into_iter().map(move |pane| PaneSnapshot {
                            tab_position,
                            id: pane.id,
                            is_plugin: pane.is_plugin,
                            is_focused: pane.is_focused,
                        })
                    })
                    .collect();
            },
            _ => {},
        }
        false
    }

    fn pipe(&mut self, pipe_message: PipeMessage) -> bool {
        match parse_pipe_command(&pipe_message.name, pipe_message.payload.as_deref()) {
            Some(PipeCommand::Switch(slot)) => self.switch_slot(slot),
            Some(PipeCommand::Save(slot)) => self.save_slot(slot),
            None => eprintln!("session-shortcuts: ignoring unsupported pipe message"),
        }
        false
    }
}

impl SessionShortcutsPlugin {
    fn switch_slot(&self, slot: u8) {
        let shortcuts = match ShortcutFile::load_or_default(&self.shortcut_file) {
            Ok(shortcuts) => shortcuts,
            Err(err) => {
                eprintln!("session-shortcuts: {err}");
                return;
            },
        };
        let Some(entry) = shortcuts.get(slot) else {
            eprintln!("session-shortcuts: no shortcut saved for slot {slot}");
            return;
        };

        if let Some(cwd) = entry.cwd.as_ref() {
            switch_session_with_cwd(Some(&entry.session), Some(PathBuf::from(cwd)));
        }

        match (entry.tab_position, entry.pane_id) {
            (tab_position, Some(pane)) => {
                switch_session_with_focus(
                    &entry.session,
                    tab_position,
                    Some((pane.id, pane.is_plugin)),
                );
            },
            (Some(tab_position), None) => {
                switch_session_with_focus(&entry.session, Some(tab_position), None);
            },
            (None, None) if entry.cwd.is_none() => {
                switch_session(Some(&entry.session));
            },
            (None, None) => {},
        }
    }

    fn save_slot(&self, slot: u8) {
        let Some(session_name) = self.session_name.as_deref() else {
            eprintln!("session-shortcuts: current session name is unavailable");
            return;
        };
        let Some(pane) = active_focused_pane(&self.tabs, &self.panes) else {
            eprintln!("session-shortcuts: focused pane is unavailable");
            return;
        };
        let cwd = get_pane_cwd(to_pane_id(pane.pane_id)).ok();
        let Some(entry) = focused_target(
            slot,
            session_name,
            cwd.as_ref().and_then(|path| path.to_str()),
            &self.tabs,
            &self.panes,
        ) else {
            eprintln!("session-shortcuts: failed to build shortcut target");
            return;
        };

        let mut shortcuts = match ShortcutFile::load_or_default(&self.shortcut_file) {
            Ok(shortcuts) => shortcuts,
            Err(err) => {
                eprintln!("session-shortcuts: {err}");
                ShortcutFile::default()
            },
        };
        shortcuts.upsert(entry);
        if let Err(err) = shortcuts.save(&self.shortcut_file) {
            eprintln!("session-shortcuts: {err}");
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct FocusedPane {
    pane_id: PaneTarget,
}

fn active_focused_pane(tabs: &[TabSnapshot], panes: &[PaneSnapshot]) -> Option<FocusedPane> {
    let active_tab = tabs.iter().find(|tab| tab.active)?;
    let pane = panes
        .iter()
        .find(|pane| pane.tab_position == active_tab.position && pane.is_focused)?;
    Some(FocusedPane {
        pane_id: PaneTarget {
            id: pane.id,
            is_plugin: pane.is_plugin,
        },
    })
}

fn to_pane_id(pane: PaneTarget) -> PaneId {
    if pane.is_plugin {
        PaneId::Plugin(pane.id)
    } else {
        PaneId::Terminal(pane.id)
    }
}

fn default_shortcut_file() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".config/zellij/session-shortcuts.tsv")
}

register_plugin!(SessionShortcutsPlugin);
