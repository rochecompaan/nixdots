package launcher

import (
	"reflect"
	"testing"
)

const windowsFixture = `[
  {"id":3,"app_id":"firefox-profile-default","pid":128592,"workspace_id":2},
  {"id":50,"app_id":"firefox-profile-clubhouse","pid":200000,"workspace_id":6}
]`

const workspaceFixture = `[
  {"id":5,"idx":5,"name":"5","output":"HDMI-A-1","active_window_id":null}
]`

func TestWindowIDsAndMatchingNewWindow(t *testing.T) {
	windows, err := decodeWindows([]byte(windowsFixture))
	if err != nil {
		t.Fatal(err)
	}

	if got, want := windowIDs(windows), map[uint64]struct{}{3: {}, 50: {}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("window IDs = %#v, want %#v", got, want)
	}
	before := map[uint64]struct{}{3: {}}
	if got, ok := matchingNewWindow(windows, before, profileAppID("clubhouse")); !ok || got != 50 {
		t.Fatalf("matching new window = (%d, %t), want (50, true)", got, ok)
	}
}

func TestWorkspaceTargetUsesOutputIndexAndNameFallback(t *testing.T) {
	workspaces, err := decodeWorkspaces([]byte(workspaceFixture))
	if err != nil {
		t.Fatal(err)
	}

	if got := workspaceTarget(workspaces, "5"); got != (workspaceTargetValue{Output: "HDMI-A-1", Reference: "5"}) {
		t.Fatalf("target = %#v", got)
	}
	if got := workspaceTarget(workspaces, "missing"); got != (workspaceTargetValue{Reference: "missing"}) {
		t.Fatalf("fallback target = %#v", got)
	}
}

func TestNiriJSONDecodingIsStrictAboutTrailingValues(t *testing.T) {
	if _, err := decodeWindows([]byte(windowsFixture + `{}`)); err == nil {
		t.Fatal("expected decoding error")
	}
}

func TestNiriJSONDecodingIgnoresUnusedFields(t *testing.T) {
	data := `[{"id":3,"title":"Firefox","app_id":"firefox-profile-default","pid":128592,"workspace_id":2,"is_focused":false,"is_floating":false,"is_urgent":false,"layout":{"window_size":[1904,1026]},"focus_timestamp":{"secs":1,"nanos":2}}]`
	windows, err := decodeWindows([]byte(data))
	if err != nil {
		t.Fatal(err)
	}
	if len(windows) != 1 || windows[0].ID != 3 || windows[0].AppID != "firefox-profile-default" {
		t.Fatalf("windows = %#v", windows)
	}
}

func TestNiriWindowDecodingRejectsMissingNullAndZeroUsedFields(t *testing.T) {
	for name, data := range map[string]string{
		"top level null": `null`,
		"missing ID":     `[{"app_id":"firefox-profile-clubhouse"}]`,
		"null ID":        `[{"id":null,"app_id":"firefox-profile-clubhouse"}]`,
		"zero ID":        `[{"id":0,"app_id":"firefox-profile-clubhouse"}]`,
		"invalid app ID": `[{"id":3,"app_id":1}]`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeWindows([]byte(data)); err == nil {
				t.Fatal("expected decoding error")
			}
		})
	}
}

func TestNiriWorkspaceDecodingRejectsMissingNullAndUnusableFields(t *testing.T) {
	for name, data := range map[string]string{
		"top level null": `null`,
		"missing index":  `[{"name":"5","output":"HDMI-A-1"}]`,
		"null index":     `[{"idx":null,"name":"5","output":"HDMI-A-1"}]`,
		"zero index":     `[{"idx":0,"name":"5","output":"HDMI-A-1"}]`,
		"invalid output": `[{"idx":5,"name":"5","output":1}]`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeWorkspaces([]byte(data)); err == nil {
				t.Fatal("expected decoding error")
			}
		})
	}
}

func TestNiriDecodingAllowsOptionalAppIDAndWorkspaceOutput(t *testing.T) {
	windows, err := decodeWindows([]byte(`[
  {"id":3,"app_id":null},
  {"id":4}
]`))
	if err != nil {
		t.Fatal(err)
	}
	if got, found := matchingNewWindow(windows, map[uint64]struct{}{}, profileAppID("clubhouse")); found || got != 0 {
		t.Fatalf("optional app IDs matched window %d", got)
	}

	for name, data := range map[string]string{
		"null output":    `[{"idx":5,"name":"5","output":null}]`,
		"missing output": `[{"idx":5,"name":"5"}]`,
	} {
		t.Run(name, func(t *testing.T) {
			workspaces, err := decodeWorkspaces([]byte(data))
			if err != nil {
				t.Fatal(err)
			}
			if got := workspaceTarget(workspaces, "5"); got != (workspaceTargetValue{Reference: "5"}) {
				t.Fatalf("output-less target = %#v", got)
			}
		})
	}
}
