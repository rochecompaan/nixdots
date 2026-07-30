package app

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestLoadApplicationStateQuarantinesOnlyTypedCorruptionPrivately(t *testing.T) {
	root := t.TempDir()
	layout := storage.Layout{DataDir: filepath.Join(root, "data"), StateDir: filepath.Join(root, "state")}
	store, err := storage.New(layout)
	if err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(layout.StateDir, "state.json")
	if err := os.WriteFile(statePath, []byte(`{"truncated":`), 0o600); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 29, 10, 11, 12, 0, time.UTC)
	got, err := loadApplicationStateWith(store, quarantineFiles{
		now:    func() time.Time { return now },
		suffix: func() (string, error) { return "fixed", nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(); err != nil || len(got.Occurrences) != 0 {
		t.Fatalf("rebuilt state = %#v err=%v", got, err)
	}
	if _, err := os.Stat(statePath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("original state still present: %v", err)
	}
	matches, err := filepath.Glob(filepath.Join(layout.StateDir, "state.json.corrupt-20260729T101112Z-fixed"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("quarantine matches=%v err=%v", matches, err)
	}
	info, err := os.Stat(matches[0])
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("quarantine mode = %o", info.Mode().Perm())
	}
	dirInfo, err := os.Stat(layout.StateDir)
	if err != nil || dirInfo.Mode().Perm() != 0o700 {
		t.Fatalf("state directory mode=%v err=%v", dirInfo.Mode().Perm(), err)
	}
}

func TestLoadApplicationStatePropagatesNonCorruptionErrorUnchanged(t *testing.T) {
	sentinel := errors.New("permission sentinel")
	_, err := loadApplicationStateWith(stateLoadFunc(func() (storage.State, error) { return storage.State{}, sentinel }), quarantineFiles{})
	if !errors.Is(err, sentinel) {
		t.Fatalf("error = %v, want sentinel", err)
	}
}

func TestLoadApplicationStatePropagatesRenameAndDirectorySyncErrors(t *testing.T) {
	for _, stage := range []string{"rename", "sync"} {
		t.Run(stage, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "state.json")
			if err := os.WriteFile(path, []byte("bad"), 0o600); err != nil {
				t.Fatal(err)
			}
			sentinel := errors.New(stage + " sentinel")
			files := quarantineFiles{suffix: func() (string, error) { return "fixed", nil }}
			if stage == "rename" {
				files.rename = func(string, string) error { return sentinel }
			} else {
				files.openDir = func(string) (syncDirectory, error) { return failingSyncDirectory{err: sentinel}, nil }
			}
			loader := stateLoadFunc(func() (storage.State, error) {
				return storage.State{}, &storage.CorruptStateError{Path: path, Err: errors.New("decode")}
			})
			if _, err := loadApplicationStateWith(loader, files); !errors.Is(err, sentinel) {
				t.Fatalf("error = %v, want sentinel", err)
			}
		})
	}
}

func TestLoadApplicationStateDoesNotOverwriteQuarantineNameCollision(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "state.json")
	if err := os.WriteFile(path, []byte("new corruption"), 0o600); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 29, 10, 11, 12, 0, time.UTC)
	occupied := path + ".corrupt-20260729T101112Z-first"
	if err := os.WriteFile(occupied, []byte("older diagnostic"), 0o600); err != nil {
		t.Fatal(err)
	}
	suffixes := []string{"first", "second"}
	loader := stateLoadFunc(func() (storage.State, error) {
		return storage.State{}, &storage.CorruptStateError{Path: path, Err: errors.New("decode")}
	})
	_, err := loadApplicationStateWith(loader, quarantineFiles{
		now: func() time.Time { return now },
		suffix: func() (string, error) {
			value := suffixes[0]
			suffixes = suffixes[1:]
			return value, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	old, err := os.ReadFile(occupied)
	if err != nil || string(old) != "older diagnostic" {
		t.Fatalf("occupied diagnostic changed: %q err=%v", old, err)
	}
	newer, err := os.ReadFile(path + ".corrupt-20260729T101112Z-second")
	if err != nil || string(newer) != "new corruption" {
		t.Fatalf("new diagnostic = %q err=%v", newer, err)
	}
}

func TestRunAndStatusUseCorruptStateBoundary(t *testing.T) {
	for _, command := range []string{"run", "status"} {
		t.Run(command, func(t *testing.T) {
			root := t.TempDir()
			layout := storage.Layout{DataDir: filepath.Join(root, "data"), StateDir: filepath.Join(root, "state")}
			store, err := storage.New(layout)
			if err != nil {
				t.Fatal(err)
			}
			statePath := filepath.Join(layout.StateDir, "state.json")
			if err := os.WriteFile(statePath, []byte(`not-json`), 0o600); err != nil {
				t.Fatal(err)
			}
			cfg := config.Config{LeadTime: 5 * time.Minute, AllowedHosts: []string{"zoom.us"}, Accounts: map[string]config.Account{"alpha": {FirefoxProfile: "clubhouse"}}}
			if command == "run" {
				err = runDaemon(context.Background(), store, cfg)
			} else {
				err = statusCommand(store, cfg)
			}
			if err == nil {
				t.Fatal("expected unavailable-account result after quarantine")
			}
			if _, statErr := os.Stat(statePath); !errors.Is(statErr, os.ErrNotExist) {
				t.Fatalf("state was not quarantined: %v", statErr)
			}
			entries, readErr := os.ReadDir(layout.StateDir)
			if readErr != nil {
				t.Fatal(readErr)
			}
			found := false
			for _, entry := range entries {
				found = found || strings.HasPrefix(entry.Name(), "state.json.corrupt-")
			}
			if !found {
				t.Fatalf("no retained diagnostic file in %#v", entries)
			}
		})
	}
}

type stateLoadFunc func() (storage.State, error)

func (f stateLoadFunc) LoadState() (storage.State, error) { return f() }

type failingSyncDirectory struct{ err error }

func (d failingSyncDirectory) Sync() error { return d.err }
func (failingSyncDirectory) Close() error  { return nil }
