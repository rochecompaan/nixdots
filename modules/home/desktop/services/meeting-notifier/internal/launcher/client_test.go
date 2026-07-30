package launcher

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
)

type runnerCall struct {
	name string
	args []string
}

type fakeRunner struct {
	calls []runnerCall
	err   error
}

func (f *fakeRunner) Run(_ context.Context, name string, args ...string) error {
	f.calls = append(f.calls, runnerCall{name: name, args: append([]string(nil), args...)})
	return f.err
}

func TestClientOpenRevalidatesAndExecutesOpaqueDirectArgv(t *testing.T) {
	runner := &fakeRunner{}
	client := NewClient(config.Config{
		FirefoxLauncherBin: "/nix/store/niri-firefox-launcher",
		Workspace:          "5",
		AllowedHosts:       []string{"meet.google.com", "*.zoom.us"},
	}, runner)
	rawURL := "https://meet.google.com/abc-defg-hij?next=$HOME;printf%20pwned&x=a%26b"

	if err := client.Open(context.Background(), "clubhouse", rawURL); err != nil {
		t.Fatal(err)
	}
	want := []runnerCall{{
		name: "/nix/store/niri-firefox-launcher",
		args: []string{"open-url", "--workspace", "5", "--profile", "clubhouse", "--url", rawURL},
	}}
	if !reflect.DeepEqual(runner.calls, want) {
		t.Fatalf("calls = %#v, want %#v", runner.calls, want)
	}
}

func TestClientOpenRejectsInvalidURLBeforeExecution(t *testing.T) {
	runner := &fakeRunner{}
	client := NewClient(config.Config{
		FirefoxLauncherBin: "/launcher",
		Workspace:          "5",
		AllowedHosts:       []string{"meet.google.com"},
	}, runner)

	if err := client.Open(context.Background(), "clubhouse", "https://meet.google.com.evil.example/pwn"); err == nil {
		t.Fatal("expected validation error")
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runner calls = %#v, want none", runner.calls)
	}
}

func TestClientOpenReturnsRunnerError(t *testing.T) {
	sentinel := errors.New("launcher failed")
	runner := &fakeRunner{err: sentinel}
	client := NewClient(config.Config{
		FirefoxLauncherBin: "/launcher",
		Workspace:          "5",
		AllowedHosts:       []string{"meet.google.com"},
	}, runner)

	err := client.Open(context.Background(), "clubhouse", "https://meet.google.com/abc")
	if !errors.Is(err, sentinel) {
		t.Fatalf("error = %v, want sentinel", err)
	}
}
