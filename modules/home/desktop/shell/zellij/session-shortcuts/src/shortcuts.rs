#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ShortcutFile {
    pub entries: Vec<ShortcutEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShortcutEntry {
    pub slot: u8,
    pub session: String,
    pub cwd: Option<String>,
    pub tab_position: Option<usize>,
    pub pane_id: Option<PaneTarget>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PaneTarget {
    pub id: u32,
    pub is_plugin: bool,
}

impl ShortcutFile {
    pub fn load_or_default(path: &std::path::Path) -> Result<Self, String> {
        match std::fs::read_to_string(path) {
            Ok(input) => Self::parse(&input),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(err) => Err(format!("failed to read {}: {}", path.display(), err)),
        }
    }

    pub fn save(&self, path: &std::path::Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| format!("failed to create {}: {}", parent.display(), err))?;
        }
        std::fs::write(path, self.to_tsv())
            .map_err(|err| format!("failed to write {}: {}", path.display(), err))
    }

    pub fn parse(input: &str) -> Result<Self, String> {
        let mut entries = Vec::new();
        for (line_index, line) in input.lines().enumerate() {
            let line = line.trim_end();
            if line.trim().is_empty() || line.trim_start().starts_with('#') {
                continue;
            }
            let columns: Vec<&str> = line.split('\t').collect();
            if columns.len() < 2 {
                return Err(format!("line {}: expected at least slot and session", line_index + 1));
            }
            let slot = parse_slot(columns[0]).map_err(|e| format!("line {}: {}", line_index + 1, e))?;
            let session = columns[1].trim().to_string();
            if session.is_empty() {
                return Err(format!("line {}: session is required", line_index + 1));
            }
            let cwd = columns.get(2).and_then(|value| non_empty(value));
            let tab_position = columns
                .get(3)
                .and_then(|value| non_empty(value))
                .map(|value| value.parse::<usize>().map_err(|_| format!("line {}: invalid tab_position", line_index + 1)))
                .transpose()?;
            let raw_pane = columns.get(4).and_then(|value| non_empty(value));
            let is_plugin = columns
                .get(5)
                .and_then(|value| non_empty(value))
                .map(|value| parse_bool(&value).map_err(|e| format!("line {}: {}", line_index + 1, e)))
                .transpose()?;
            let pane_id = raw_pane
                .map(|value| parse_pane_target(&value, is_plugin).map_err(|e| format!("line {}: {}", line_index + 1, e)))
                .transpose()?;

            entries.push(ShortcutEntry {
                slot,
                session,
                cwd,
                tab_position,
                pane_id,
            });
        }
        let mut shortcuts = ShortcutFile { entries };
        shortcuts.sort_entries();
        Ok(shortcuts)
    }

    pub fn to_tsv(&self) -> String {
        let mut output = "# slot\tsession\tcwd\ttab_position\tpane_id\tis_plugin\n".to_string();
        let mut entries = self.entries.clone();
        entries.sort_by_key(|entry| entry.slot);
        for entry in entries {
            let cwd = entry.cwd.unwrap_or_default();
            let tab_position = entry.tab_position.map(|value| value.to_string()).unwrap_or_default();
            let pane_id = entry.pane_id.map(format_pane_target).unwrap_or_default();
            let is_plugin = entry
                .pane_id
                .map(|pane| pane.is_plugin.to_string())
                .unwrap_or_default();
            output.push_str(&format!(
                "{}\t{}\t{}\t{}\t{}\t{}\n",
                entry.slot, session_escape(&entry.session), cwd, tab_position, pane_id, is_plugin
            ));
        }
        output
    }

    pub fn get(&self, slot: u8) -> Option<&ShortcutEntry> {
        self.entries.iter().find(|entry| entry.slot == slot)
    }

    pub fn upsert(&mut self, entry: ShortcutEntry) {
        self.entries.retain(|existing| existing.slot != entry.slot);
        self.entries.push(entry);
        self.sort_entries();
    }

    fn sort_entries(&mut self) {
        self.entries.sort_by_key(|entry| entry.slot);
    }
}

fn parse_slot(value: &str) -> Result<u8, String> {
    let slot = value.trim().parse::<u8>().map_err(|_| "invalid slot".to_string())?;
    if (1..=9).contains(&slot) {
        Ok(slot)
    } else {
        Err("slot must be between 1 and 9".to_string())
    }
}

fn parse_bool(value: &str) -> Result<bool, String> {
    match value.trim() {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err("is_plugin must be true or false".to_string()),
    }
}

fn parse_pane_target(value: &str, is_plugin: Option<bool>) -> Result<PaneTarget, String> {
    if let Some(id) = value.strip_prefix("terminal_") {
        return Ok(PaneTarget {
            id: parse_pane_id(id)?,
            is_plugin: false,
        });
    }
    if let Some(id) = value.strip_prefix("plugin_") {
        return Ok(PaneTarget {
            id: parse_pane_id(id)?,
            is_plugin: true,
        });
    }
    Ok(PaneTarget {
        id: parse_pane_id(value)?,
        is_plugin: is_plugin.unwrap_or(false),
    })
}

fn parse_pane_id(value: &str) -> Result<u32, String> {
    value.trim().parse::<u32>().map_err(|_| "invalid pane_id".to_string())
}

fn format_pane_target(pane: PaneTarget) -> String {
    if pane.is_plugin {
        format!("plugin_{}", pane.id)
    } else {
        format!("terminal_{}", pane.id)
    }
}

fn non_empty(value: &&str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn session_escape(session: &str) -> String {
    session.replace('\t', " ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tsv_with_comments_and_terminal_pane_id() {
        let file = "# slot\tsession\tcwd\ttab_position\tpane_id\tis_plugin\n1\tnixdots\t/home/roche/nixdots\t0\tterminal_16\tfalse\n";

        let shortcuts = ShortcutFile::parse(file).expect("valid shortcuts file");

        assert_eq!(shortcuts.entries.len(), 1);
        assert_eq!(shortcuts.entries[0].slot, 1);
        assert_eq!(shortcuts.entries[0].session, "nixdots");
        assert_eq!(shortcuts.entries[0].cwd.as_deref(), Some("/home/roche/nixdots"));
        assert_eq!(shortcuts.entries[0].tab_position, Some(0));
        assert_eq!(shortcuts.entries[0].pane_id, Some(PaneTarget { id: 16, is_plugin: false }));
    }

    #[test]
    fn serializes_entries_in_slot_order() {
        let mut shortcuts = ShortcutFile::default();
        shortcuts.upsert(ShortcutEntry {
            slot: 2,
            session: "mycity".to_string(),
            cwd: Some("/home/roche/projects/mycity".to_string()),
            tab_position: Some(1),
            pane_id: Some(PaneTarget { id: 7, is_plugin: false }),
        });
        shortcuts.upsert(ShortcutEntry {
            slot: 1,
            session: "nixdots".to_string(),
            cwd: Some("/home/roche/nixdots".to_string()),
            tab_position: Some(0),
            pane_id: Some(PaneTarget { id: 16, is_plugin: false }),
        });

        assert_eq!(
            shortcuts.to_tsv(),
            "# slot\tsession\tcwd\ttab_position\tpane_id\tis_plugin\n1\tnixdots\t/home/roche/nixdots\t0\tterminal_16\tfalse\n2\tmycity\t/home/roche/projects/mycity\t1\tterminal_7\tfalse\n"
        );
    }

    #[test]
    fn upsert_replaces_existing_slot() {
        let mut shortcuts = ShortcutFile::parse("1\told\t/tmp\t0\tterminal_1\tfalse\n").expect("valid input");

        shortcuts.upsert(ShortcutEntry {
            slot: 1,
            session: "new".to_string(),
            cwd: Some("/work".to_string()),
            tab_position: Some(3),
            pane_id: Some(PaneTarget { id: 9, is_plugin: true }),
        });

        assert_eq!(shortcuts.entries.len(), 1);
        assert_eq!(shortcuts.entries[0].session, "new");
        assert_eq!(shortcuts.entries[0].pane_id, Some(PaneTarget { id: 9, is_plugin: true }));
        assert!(shortcuts.to_tsv().contains("1\tnew\t/work\t3\tplugin_9\ttrue\n"));
    }

    #[test]
    fn rejects_slot_outside_number_key_range() {
        let err = ShortcutFile::parse("10\tbad\t/tmp\t0\tterminal_1\tfalse\n").expect_err("slot should fail");

        assert!(err.contains("slot must be between 1 and 9"));
    }

    #[test]
    fn saves_and_loads_shortcut_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nested/session-shortcuts.tsv");
        let mut shortcuts = ShortcutFile::default();
        shortcuts.upsert(ShortcutEntry {
            slot: 4,
            session: "croprun".to_string(),
            cwd: Some("/home/roche/projects/croprun".to_string()),
            tab_position: Some(2),
            pane_id: Some(PaneTarget { id: 3, is_plugin: false }),
        });

        shortcuts.save(&path).expect("save shortcuts");
        let loaded = ShortcutFile::load_or_default(&path).expect("load shortcuts");

        assert_eq!(loaded.entries, shortcuts.entries);
    }
}
