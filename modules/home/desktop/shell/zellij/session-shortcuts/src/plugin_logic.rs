use crate::shortcuts::{PaneTarget, ShortcutEntry};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipeCommand {
    Switch(u8),
    Save(u8),
}

pub fn parse_pipe_command(name: &str, payload: Option<&str>) -> Option<PipeCommand> {
    let slot = payload?.trim().parse::<u8>().ok()?;
    if !(1..=9).contains(&slot) {
        return None;
    }
    match name {
        "switch" => Some(PipeCommand::Switch(slot)),
        "save" => Some(PipeCommand::Save(slot)),
        _ => None,
    }
}

pub fn focused_target(
    slot: u8,
    session: &str,
    cwd: Option<&str>,
    tabs: &[TabSnapshot],
    panes: &[PaneSnapshot],
) -> Option<ShortcutEntry> {
    let active_tab = tabs.iter().find(|tab| tab.active)?;
    let focused_pane = panes
        .iter()
        .find(|pane| pane.tab_position == active_tab.position && pane.is_focused)?;
    Some(ShortcutEntry {
        slot,
        session: session.to_string(),
        cwd: cwd.map(ToString::to_string),
        tab_position: Some(active_tab.position),
        pane_id: Some(PaneTarget {
            id: focused_pane.id,
            is_plugin: focused_pane.is_plugin,
        }),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabSnapshot {
    pub position: usize,
    pub active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneSnapshot {
    pub tab_position: usize,
    pub id: u32,
    pub is_plugin: bool,
    pub is_focused: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supported_pipe_commands() {
        assert_eq!(parse_pipe_command("switch", Some("1")), Some(PipeCommand::Switch(1)));
        assert_eq!(parse_pipe_command("save", Some("9")), Some(PipeCommand::Save(9)));
        assert_eq!(parse_pipe_command("save", Some("10")), None);
        assert_eq!(parse_pipe_command("unknown", Some("1")), None);
        assert_eq!(parse_pipe_command("save", None), None);
    }

    #[test]
    fn captures_focused_pane_from_active_tab() {
        let tabs = vec![
            TabSnapshot { position: 0, active: false },
            TabSnapshot { position: 1, active: true },
        ];
        let panes = vec![
            PaneSnapshot { tab_position: 0, id: 4, is_plugin: false, is_focused: true },
            PaneSnapshot { tab_position: 1, id: 7, is_plugin: false, is_focused: true },
        ];

        let target = focused_target(2, "nixdots", Some("/home/roche/nixdots"), &tabs, &panes)
            .expect("focused pane target");

        assert_eq!(
            target,
            ShortcutEntry {
                slot: 2,
                session: "nixdots".to_string(),
                cwd: Some("/home/roche/nixdots".to_string()),
                tab_position: Some(1),
                pane_id: Some(PaneTarget { id: 7, is_plugin: false }),
            }
        );
    }
}
