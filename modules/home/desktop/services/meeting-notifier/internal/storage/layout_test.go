package storage

import (
	"path/filepath"
	"testing"
)

func TestDefaultLayoutUsesXDGDirectories(t *testing.T) {
	t.Setenv("HOME", "")
	t.Setenv("XDG_CONFIG_HOME", "/xdg/config")
	t.Setenv("XDG_DATA_HOME", "/xdg/data")
	t.Setenv("XDG_STATE_HOME", "/xdg/state")

	layout, err := DefaultLayout()
	if err != nil {
		t.Fatal(err)
	}
	want := Layout{
		ConfigFile:  "/xdg/config/meeting-notifier/config.json",
		DataDir:     "/xdg/data/meeting-notifier",
		StateDir:    "/xdg/state/meeting-notifier",
		AccountsDir: "/xdg/data/meeting-notifier/accounts",
		StateFile:   "/xdg/state/meeting-notifier/state.json",
	}
	if layout != want {
		t.Fatalf("DefaultLayout() = %#v, want %#v", layout, want)
	}
}

func TestDefaultLayoutFallsBackBelowHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("XDG_DATA_HOME", "")
	t.Setenv("XDG_STATE_HOME", "")

	layout, err := DefaultLayout()
	if err != nil {
		t.Fatal(err)
	}
	if layout.ConfigFile != filepath.Join(home, ".config", "meeting-notifier", "config.json") {
		t.Fatalf("unexpected config path %q", layout.ConfigFile)
	}
	if layout.AccountsDir != filepath.Join(home, ".local", "share", "meeting-notifier", "accounts") {
		t.Fatalf("unexpected accounts path %q", layout.AccountsDir)
	}
	if layout.StateFile != filepath.Join(home, ".local", "state", "meeting-notifier", "state.json") {
		t.Fatalf("unexpected state path %q", layout.StateFile)
	}
}
