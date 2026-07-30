package storage

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
)

type Store struct {
	layout Layout
	ops    fileOperations
}

func New(layout Layout) (*Store, error) {
	layout = completeLayout(layout)
	if layout.DataDir == "" || layout.StateDir == "" {
		return nil, &ValidationError{Field: "layout data and state directories"}
	}
	for _, path := range []string{layout.DataDir, layout.StateDir, layout.AccountsDir} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return nil, fmt.Errorf("create private directory %s: %w", path, err)
		}
		if err := os.Chmod(path, 0o700); err != nil {
			return nil, fmt.Errorf("set private directory permissions %s: %w", path, err)
		}
	}
	return &Store{layout: layout, ops: defaultFileOperations()}, nil
}

func (s *Store) SaveState(state State) error {
	if _, err := state.NormalizeLegacy(); err != nil {
		return err
	}
	if err := state.Validate(); err != nil {
		return err
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return atomicWrite(s.ops, s.layout.StateFile, data)
}

func (s *Store) LoadState() (State, error) {
	data, err := readFile(s.ops, s.layout.StateFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return NewState(), nil
		}
		return State{}, err
	}
	var state State
	if err := decodeStrict(data, &state); err != nil {
		return State{}, &CorruptStateError{Path: s.layout.StateFile, Err: err}
	}
	var validated State
	if err := decodeStrict(data, &validated); err != nil {
		return State{}, &CorruptStateError{Path: s.layout.StateFile, Err: err}
	}
	if _, err := validated.NormalizeLegacy(); err != nil {
		return State{}, &CorruptStateError{Path: s.layout.StateFile, Err: err}
	}
	return state, nil
}

func decodeStrict(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("JSON must contain exactly one value")
		}
		return err
	}
	return nil
}
