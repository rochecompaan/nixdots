package launcher

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
)

type niriWindow struct {
	ID    uint64
	AppID string
}

type niriWorkspace struct {
	Index  int
	Name   *string
	Output string
}

type workspaceTargetValue struct {
	Output    string
	Reference string
}

type niriWindowWire struct {
	ID    json.RawMessage `json:"id"`
	AppID json.RawMessage `json:"app_id"`
}

type niriWorkspaceWire struct {
	Index  json.RawMessage `json:"idx"`
	Name   *string         `json:"name"`
	Output json.RawMessage `json:"output"`
}

func decodeWindows(data []byte) ([]niriWindow, error) {
	entries, err := decodeArray(data)
	if err != nil {
		return nil, fmt.Errorf("decode Niri windows: %w", err)
	}
	windows := make([]niriWindow, 0, len(entries))
	for index, entry := range entries {
		var wire niriWindowWire
		if err := json.Unmarshal(entry, &wire); err != nil {
			return nil, fmt.Errorf("decode Niri window %d: %w", index, err)
		}
		id, err := requiredUint64(wire.ID, "window id")
		if err != nil {
			return nil, fmt.Errorf("decode Niri window %d: %w", index, err)
		}
		appID, err := optionalString(wire.AppID, "window app ID")
		if err != nil {
			return nil, fmt.Errorf("decode Niri window %d: %w", index, err)
		}
		windows = append(windows, niriWindow{ID: id, AppID: appID})
	}
	return windows, nil
}

func decodeWorkspaces(data []byte) ([]niriWorkspace, error) {
	entries, err := decodeArray(data)
	if err != nil {
		return nil, fmt.Errorf("decode Niri workspaces: %w", err)
	}
	workspaces := make([]niriWorkspace, 0, len(entries))
	for position, entry := range entries {
		var wire niriWorkspaceWire
		if err := json.Unmarshal(entry, &wire); err != nil {
			return nil, fmt.Errorf("decode Niri workspace %d: %w", position, err)
		}
		index, err := requiredIndex(wire.Index)
		if err != nil {
			return nil, fmt.Errorf("decode Niri workspace %d: %w", position, err)
		}
		output, err := optionalString(wire.Output, "workspace output")
		if err != nil {
			return nil, fmt.Errorf("decode Niri workspace %d: %w", position, err)
		}
		workspaces = append(workspaces, niriWorkspace{Index: index, Name: wire.Name, Output: output})
	}
	return workspaces, nil
}

func decodeArray(data []byte) ([]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return nil, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("expected exactly one JSON value")
		}
		return nil, err
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil, errors.New("expected JSON array, got null")
	}
	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, err
	}
	return entries, nil
}

func requiredUint64(raw json.RawMessage, field string) (uint64, error) {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return 0, fmt.Errorf("%s is required", field)
	}
	var value uint64
	if err := json.Unmarshal(raw, &value); err != nil {
		return 0, fmt.Errorf("decode %s: %w", field, err)
	}
	if value == 0 {
		return 0, fmt.Errorf("%s must be non-zero", field)
	}
	return value, nil
}

func requiredIndex(raw json.RawMessage) (int, error) {
	value, err := requiredUint64(raw, "workspace index")
	if err != nil {
		return 0, err
	}
	maxInt := uint64(^uint(0) >> 1)
	if value > maxInt {
		return 0, errors.New("workspace index overflows int")
	}
	return int(value), nil
}

func optionalString(raw json.RawMessage, field string) (string, error) {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return "", nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", fmt.Errorf("decode %s: %w", field, err)
	}
	return value, nil
}

func windowIDs(windows []niriWindow) map[uint64]struct{} {
	result := make(map[uint64]struct{}, len(windows))
	for _, window := range windows {
		result[window.ID] = struct{}{}
	}
	return result
}

func newWindowIDs(windows []niriWindow, before map[uint64]struct{}) []uint64 {
	var result []uint64
	for _, window := range windows {
		if _, existed := before[window.ID]; !existed {
			result = append(result, window.ID)
		}
	}
	return result
}

func matchingNewWindow(windows []niriWindow, before map[uint64]struct{}, appID string) (uint64, bool) {
	for _, window := range windows {
		if _, existed := before[window.ID]; !existed && window.AppID == appID {
			return window.ID, true
		}
	}
	return 0, false
}

func workspaceTarget(workspaces []niriWorkspace, name string) workspaceTargetValue {
	for _, workspace := range workspaces {
		if workspace.Name != nil && *workspace.Name == name {
			if workspace.Output == "" {
				return workspaceTargetValue{Reference: name}
			}
			return workspaceTargetValue{
				Output:    workspace.Output,
				Reference: strconv.Itoa(workspace.Index),
			}
		}
	}
	return workspaceTargetValue{Reference: name}
}

func profileAppID(profile string) string {
	return "firefox-profile-" + profile
}
