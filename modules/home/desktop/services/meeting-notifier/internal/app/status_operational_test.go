package app

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestConcreteStatusUsesBundleSummariesInjectedNowAndRedactsSensitiveFields(t *testing.T) {
	root := t.TempDir()
	store, err := storage.New(storage.Layout{DataDir: filepath.Join(root, "data"), StateDir: filepath.Join(root, "state")})
	if err != nil {
		t.Fatal(err)
	}
	bundle := validAuthorizationBundle()
	bundle.Calendars = []storage.CalendarRef{{ID: "calendar-id-sentinel", Summary: "Engineering"}}
	if err := store.SaveAuthorization("alpha", bundle); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	item := meeting.Meeting{Key: "next", AccountLabel: "alpha", CalendarID: "calendar-id-sentinel", Summary: "Standup", Start: now.Add(time.Minute), URL: "https://zoom.us/j/123?token=sentinel"}
	state := storage.NewState()
	state.Snapshots["alpha"] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{item}}
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseScheduled}
	if err := store.SaveState(state); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{PollInterval: time.Minute, Accounts: map[string]config.Account{"alpha": {FirefoxProfile: "clubhouse"}}}
	var output bytes.Buffer
	if err := statusCommandAt(store, cfg, &output, now); err != nil {
		t.Fatal(err)
	}
	got := output.String()
	for _, field := range []string{"alpha: available", `calendars=["Engineering"]`, "cache-age=1m0s", "freshness=fresh", `next-title="Standup"`, "next-phase=scheduled"} {
		if !strings.Contains(got, field) {
			t.Fatalf("missing %q in %q", field, got)
		}
	}
	for _, secret := range []string{"calendar-id-sentinel", "zoom.us", "token=sentinel", bundle.Identity, bundle.Token.RefreshToken} {
		if secret != "" && strings.Contains(got, secret) {
			t.Fatalf("status leaked %q in %q", secret, got)
		}
	}
}
