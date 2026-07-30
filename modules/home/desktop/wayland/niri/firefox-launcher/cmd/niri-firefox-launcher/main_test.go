package main

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/rochecompaan/nixdots/niri-firefox-launcher/internal/launcher"
)

type fakeService struct {
	calls [][]string
}

func (f *fakeService) LaunchProfile(_ context.Context, workspace, profile string) error {
	f.calls = append(f.calls, []string{"launch-profile", workspace, profile})
	return nil
}

func (f *fakeService) OpenURL(_ context.Context, workspace, profile, rawURL string) error {
	f.calls = append(f.calls, []string{"open-url", workspace, profile, rawURL})
	return nil
}

func (f *fakeService) FocusWorkspace(_ context.Context, workspace string) error {
	f.calls = append(f.calls, []string{"focus-workspace", workspace})
	return nil
}

func TestRunDispatchesCommandsUsingTrustedBinaryEnvironment(t *testing.T) {
	service := &fakeService{}
	var gotFirefox, gotNiri string
	factory := func(firefoxBin, niriBin string) commandService {
		gotFirefox, gotNiri = firefoxBin, niriBin
		return service
	}
	lookup := func(key string) string {
		return map[string]string{"FIREFOX_BIN": "/nix/store/firefox", "NIRI_BIN": "/nix/store/niri"}[key]
	}
	rawURL := "https://meet.google.com/abc?x=a;b=$HOME"

	if err := run(context.Background(), []string{"open-url", "--workspace", "5", "--profile", "clubhouse", "--url", rawURL}, lookup, factory); err != nil {
		t.Fatal(err)
	}
	if gotFirefox != "/nix/store/firefox" || gotNiri != "/nix/store/niri" {
		t.Fatalf("factory bins = (%q, %q)", gotFirefox, gotNiri)
	}
	if got, want := service.calls, [][]string{{"open-url", "5", "clubhouse", rawURL}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("calls = %#v, want %#v", got, want)
	}
}

func TestRunRejectsInvalidCLIWithoutDispatch(t *testing.T) {
	tests := map[string][]string{
		"unknown command":   {"bogus"},
		"unknown argument":  {"focus-workspace", "--workspace", "2", "extra"},
		"unknown flag":      {"focus-workspace", "--workspace", "2", "--bogus"},
		"missing workspace": {"focus-workspace"},
		"missing profile":   {"launch-profile", "--workspace", "6"},
		"missing URL":       {"open-url", "--workspace", "5", "--profile", "clubhouse"},
	}
	for name, args := range tests {
		t.Run(name, func(t *testing.T) {
			service := &fakeService{}
			err := run(context.Background(), args, func(string) string { return "/trusted" }, func(_, _ string) commandService { return service })
			if err == nil {
				t.Fatal("expected error")
			}
			if len(service.calls) != 0 {
				t.Fatalf("unexpected dispatch: %#v", service.calls)
			}
		})
	}
}

func TestExitCodeUsesStableLauncherProtocol(t *testing.T) {
	if got := exitCode(launcher.ErrWindowTimeout); got != exitWindowTimeout {
		t.Fatalf("window timeout exit code = %d", got)
	}
	if got := exitCode(context.DeadlineExceeded); got != exitCommandTimeout {
		t.Fatalf("command timeout exit code = %d", got)
	}
}

func TestRunRequiresWrapperBinaryEnvironment(t *testing.T) {
	err := run(context.Background(), []string{"focus-workspace", "--workspace", "2"}, func(string) string { return "" }, func(_, _ string) commandService {
		t.Fatal("factory must not be called")
		return nil
	})
	if err == nil || !errors.Is(err, errMissingBinaryEnvironment) {
		t.Fatalf("error = %v, want missing binary environment", err)
	}
}
