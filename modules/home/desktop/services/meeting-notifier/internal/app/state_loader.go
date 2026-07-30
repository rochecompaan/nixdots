package app

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type applicationStateStore interface {
	LoadState() (storage.State, error)
}

type syncDirectory interface {
	Sync() error
	Close() error
}

type quarantineFiles struct {
	now     func() time.Time
	suffix  func() (string, error)
	lstat   func(string) (os.FileInfo, error)
	rename  func(string, string) error
	openDir func(string) (syncDirectory, error)
}

func loadApplicationState(store applicationStateStore) (storage.State, error) {
	return loadApplicationStateWith(store, quarantineFiles{})
}

func loadApplicationStateWith(store applicationStateStore, files quarantineFiles) (storage.State, error) {
	state, err := store.LoadState()
	if err == nil {
		return state, nil
	}
	var corrupt *storage.CorruptStateError
	if !errors.As(err, &corrupt) {
		return storage.State{}, err
	}
	files = files.withDefaults()
	if err := quarantineCorruptState(corrupt.Path, files); err != nil {
		return storage.State{}, err
	}
	return storage.NewState(), nil
}

func (f quarantineFiles) withDefaults() quarantineFiles {
	if f.now == nil {
		f.now = time.Now
	}
	if f.suffix == nil {
		f.suffix = randomQuarantineSuffix
	}
	if f.lstat == nil {
		f.lstat = os.Lstat
	}
	if f.rename == nil {
		f.rename = os.Rename
	}
	if f.openDir == nil {
		f.openDir = func(path string) (syncDirectory, error) { return os.Open(path) }
	}
	return f
}

func quarantineCorruptState(path string, files quarantineFiles) error {
	directory := filepath.Dir(path)
	stamp := files.now().UTC().Format("20060102T150405Z")
	var destination string
	for {
		suffix, err := files.suffix()
		if err != nil {
			return err
		}
		destination = path + ".corrupt-" + stamp + "-" + suffix
		if _, err := files.lstat(destination); errors.Is(err, os.ErrNotExist) {
			break
		} else if err != nil {
			return err
		}
	}
	if err := files.rename(path, destination); err != nil {
		return err
	}
	parent, err := files.openDir(directory)
	if err != nil {
		return err
	}
	if err := parent.Sync(); err != nil {
		_ = parent.Close()
		return err
	}
	return parent.Close()
}

func randomQuarantineSuffix() (string, error) {
	var value [8]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}
