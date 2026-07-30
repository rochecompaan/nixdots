package status

import (
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/availability"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestRenderRedactsSecretsAndURLs(t *testing.T) {
	meetingURL := strings.Join([]string{"https://acme.zoom.us/j/9135550199", "source=sentinel"}, "?")
	state := storage.NewState()
	state.Health["alpha"] = storage.Health{LastSuccess: time.Now(), LastError: "sentinel-access-token-7b2f credentials-sentinel auth-code-sentinel"}
	state.Snapshots["alpha"] = storage.Snapshot{Meetings: []meeting.Meeting{{AccountLabel: "alpha", CalendarID: "calendar-id-sentinel", Summary: "sentinel confidential event description", URL: meetingURL}}}
	got := Render(state, []Account{{Label: "alpha", Category: availability.AuthRequired}})
	for _, secret := range []string{"sentinel-access-token-7b2f", "sentinel-refresh-token-91cd", "credentials-sentinel", "auth-code-sentinel", "calendar-id-sentinel", meetingURL, "sentinel confidential event description"} {
		if strings.Contains(got, secret) {
			t.Fatalf("status leaked %q in %q", secret, got)
		}
	}
	if !strings.Contains(got, "alpha") || !strings.Contains(got, "auth-required") || !strings.Contains(got, "last-error=unknown") {
		t.Fatalf("missing stable status: %q", got)
	}
}

func TestRenderIncludesStablePersistedPollCategory(t *testing.T) {
	for _, category := range []string{"transient", "authentication", "rate-limit", "permanent"} {
		state := storage.NewState()
		state.Health["alpha"] = storage.Health{LastError: category}
		got := Render(state, []Account{{Label: "alpha"}})
		if !strings.Contains(got, "last-error="+category) {
			t.Fatalf("category %q missing from %q", category, got)
		}
	}
}

func TestUnavailableUsesTypedCategory(t *testing.T) {
	if Unavailable([]Account{{Label: "alpha"}}) {
		t.Fatal("default available account reported unavailable")
	}
	if Unavailable([]Account{{Label: "alpha", Category: availability.Available}}) {
		t.Fatal("available account reported unavailable")
	}
	if !Unavailable([]Account{{Label: "alpha", Category: availability.AuthRequired}}) {
		t.Fatal("auth-required account reported available")
	}
}

func TestRenderAtIncludesCalendarsFreshnessAndNextLifecycle(t *testing.T) {
	zone := time.FixedZone("local", -4*60*60)
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, zone)
	next := meeting.Meeting{Key: "next", AccountLabel: "alpha", Summary: "Planning", Start: now.Add(10 * time.Minute), URL: "https://zoom.us/j/123"}
	later := meeting.Meeting{Key: "later", AccountLabel: "alpha", Summary: "Later", Start: now.Add(time.Hour), URL: "https://meet.google.com/abc"}
	state := storage.NewState()
	state.Snapshots["alpha"] = storage.Snapshot{FetchedAt: now.Add(-3 * time.Minute), Meetings: []meeting.Meeting{later, next}}
	state.Occurrences[next.Key] = storage.OccurrenceState{Meeting: next, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	got := RenderAt(state, []Account{{Label: "alpha", CalendarSummaries: []string{"Team", "Private"}}}, now, 5*time.Minute)
	for _, field := range []string{
		`calendars=["Private","Team"]`,
		"cache-age=3m0s",
		"freshness=fresh",
		`next-title="Planning"`,
		"next-start=2026-07-29T09:10:00-04:00",
		"next-phase=notified",
	} {
		if !strings.Contains(got, field) {
			t.Fatalf("missing %q in %q", field, got)
		}
	}
}

func TestRenderAtMarksStaleCacheAndRedactsOperationalSentinels(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	secretURL := "https://zoom.us/j/123?token=sentinel"
	state := storage.NewState()
	state.Snapshots["alpha"] = storage.Snapshot{FetchedAt: now.Add(-10 * time.Minute), Meetings: []meeting.Meeting{{Key: "next", AccountLabel: "alpha", CalendarID: "calendar-id-sentinel", Summary: "Planning " + secretURL, Start: now.Add(time.Minute), URL: secretURL}}}
	got := RenderAt(state, []Account{{Label: "alpha", CalendarSummaries: []string{"Team " + secretURL}}}, now, 5*time.Minute)
	if !strings.Contains(got, "freshness=stale") || !strings.Contains(got, "[redacted-url]") {
		t.Fatalf("missing stale/redacted status: %q", got)
	}
	for _, secret := range []string{secretURL, "calendar-id-sentinel", "token=sentinel"} {
		if strings.Contains(got, secret) {
			t.Fatalf("status leaked %q in %q", secret, got)
		}
	}
}
