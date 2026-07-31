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

func TestClientOpenRewritesZoomJoinURLForWebClient(t *testing.T) {
	runner := &fakeRunner{}
	client := NewClient(config.Config{
		FirefoxLauncherBin: "/nix/store/niri-firefox-launcher",
		Workspace:          "5",
		AllowedHosts:       []string{"zoom.us", "*.zoom.us"},
	}, runner)
	rawURL := "https://sixfeetup.zoom.us/j/87625926941?pwd=a%2Bb%2Fc%3D&tracking=drop#fragment"

	if err := client.Open(context.Background(), "sixfeetup", rawURL); err != nil {
		t.Fatal(err)
	}
	want := []runnerCall{{
		name: "/nix/store/niri-firefox-launcher",
		args: []string{
			"open-url",
			"--workspace", "5",
			"--profile", "sixfeetup",
			"--url", "https://sixfeetup.zoom.us/wc/87625926941/start?fromPWA=1&pwd=a%2Bb%2Fc%3D&ref_from=launch",
		},
	}}
	if !reflect.DeepEqual(runner.calls, want) {
		t.Fatalf("calls = %#v, want %#v", runner.calls, want)
	}
}

func TestClientOpenRevalidatesTransformedURLBeforeExecution(t *testing.T) {
	runner := &fakeRunner{}
	client := NewClient(config.Config{
		FirefoxLauncherBin: "/launcher",
		Workspace:          "5",
		AllowedHosts:       []string{"zoom.us", "*.zoom.us"},
	}, runner)
	client.transformURL = func(string) (string, error) {
		return "https://zoom.us.evil.example/wc/123/start", nil
	}

	if err := client.Open(context.Background(), "sixfeetup", "https://zoom.us/j/123"); err == nil {
		t.Fatal("expected transformed URL validation error")
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runner calls = %#v, want none", runner.calls)
	}
}

func TestClientOpenDoesNotExecuteWhenURLTransformationFails(t *testing.T) {
	sentinel := errors.New("transform failed")
	runner := &fakeRunner{}
	client := NewClient(config.Config{
		FirefoxLauncherBin: "/launcher",
		Workspace:          "5",
		AllowedHosts:       []string{"zoom.us", "*.zoom.us"},
	}, runner)
	client.transformURL = func(string) (string, error) {
		return "", sentinel
	}

	err := client.Open(context.Background(), "sixfeetup", "https://zoom.us/j/123")
	if !errors.Is(err, sentinel) {
		t.Fatalf("error = %v, want sentinel", err)
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runner calls = %#v, want none", runner.calls)
	}
}
