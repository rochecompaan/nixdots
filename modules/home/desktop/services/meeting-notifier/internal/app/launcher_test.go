package app

import (
	"context"
	"testing"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
)

type launchCall struct{ profile, url string }
type recordingLauncher struct{ calls []launchCall }

func (r *recordingLauncher) Open(_ context.Context, profile, url string) error {
	r.calls = append(r.calls, launchCall{profile, url})
	return nil
}
func TestProfileLauncherMapsConfiguredAccountLabels(t *testing.T) {
	base := &recordingLauncher{}
	adapter := profileLauncher{accounts: map[string]config.Account{"upfront": {FirefoxProfile: "default"}, "sixfeetup": {FirefoxProfile: "sixfeetup"}, "alpha": {FirefoxProfile: "clubhouse"}}, launcher: base}
	for label, want := range map[string]string{"upfront": "default", "sixfeetup": "sixfeetup", "alpha": "clubhouse"} {
		if err := adapter.Open(context.Background(), label, "https://zoom.us/j/1"); err != nil {
			t.Fatal(err)
		}
		if got := base.calls[len(base.calls)-1].profile; got != want {
			t.Fatalf("%s: %s", label, got)
		}
	}
	if adapter.Open(context.Background(), "unknown", "https://zoom.us/j/1") == nil {
		t.Fatal("accepted unknown label")
	}
}
