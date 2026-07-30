package storage

import (
	"os"
	"path/filepath"
)

const applicationDir = "meeting-notifier"

type Layout struct {
	ConfigFile  string
	DataDir     string
	StateDir    string
	AccountsDir string
	StateFile   string
}

func DefaultLayout() (Layout, error) {
	configRoot := os.Getenv("XDG_CONFIG_HOME")
	dataRoot := os.Getenv("XDG_DATA_HOME")
	stateRoot := os.Getenv("XDG_STATE_HOME")
	if configRoot == "" || dataRoot == "" || stateRoot == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return Layout{}, err
		}
		if configRoot == "" {
			configRoot = filepath.Join(home, ".config")
		}
		if dataRoot == "" {
			dataRoot = filepath.Join(home, ".local", "share")
		}
		if stateRoot == "" {
			stateRoot = filepath.Join(home, ".local", "state")
		}
	}
	return completeLayout(Layout{
		ConfigFile: filepath.Join(configRoot, applicationDir, "config.json"),
		DataDir:    filepath.Join(dataRoot, applicationDir),
		StateDir:   filepath.Join(stateRoot, applicationDir),
	}), nil
}

func completeLayout(layout Layout) Layout {
	if layout.AccountsDir == "" {
		layout.AccountsDir = filepath.Join(layout.DataDir, "accounts")
	}
	if layout.StateFile == "" {
		layout.StateFile = filepath.Join(layout.StateDir, "state.json")
	}
	return layout
}
