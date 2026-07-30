package storage

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
)

func TestLegacyJoinPendingRevisionMigratesAndValidatesStrictly(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	item := migrationMeeting("key")
	legacy := NewState()
	legacy.Occurrences[item.Key] = OccurrenceState{Meeting: item, Phase: PhaseJoinPending, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now, ResumePhase: PhaseNotified}
	if err := legacy.Validate(); err == nil {
		t.Fatal("zero join revision passed strict validation")
	}
	changed, err := legacy.NormalizeLegacy()
	if err != nil {
		t.Fatal(err)
	}
	if !changed || legacy.Occurrences[item.Key].JoinRevision != 1 {
		t.Fatalf("legacy join revision = %#v", legacy.Occurrences[item.Key])
	}
	if err := legacy.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestStoreLoadsMigratableLegacyJoinPendingWithoutMutatingFile(t *testing.T) {
	root := t.TempDir()
	layout := Layout{DataDir: filepath.Join(root, "data"), StateDir: filepath.Join(root, "state")}
	store, err := New(layout)
	if err != nil {
		t.Fatal(err)
	}
	body := `{"version":1,"snapshots":{},"occurrences":{"key":{"meeting":{"key":"key","accountLabel":"alpha","calendarId":"cal","eventId":"event","summary":"meeting","start":"2026-07-29T09:10:00Z","end":"2026-07-29T10:10:00Z","url":"https://zoom.us/j/123"},"phase":"join-pending","notificationId":7,"notifiedAt":"2026-07-29T09:00:00Z","actionExpiresAt":"2026-07-29T10:00:00Z","joinRequestedAt":"2026-07-29T09:00:00Z","resumePhase":"notified"}},"authWarnings":{},"authWarningRevisions":{},"pendingAuthWarnings":{},"health":{}}`
	path := filepath.Join(layout.StateDir, "state.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := store.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Occurrences["key"].JoinRevision != 0 {
		t.Fatalf("LoadState mutated legacy data: %#v", loaded.Occurrences["key"])
	}
	after, err := os.ReadFile(path)
	if err != nil || string(after) != body {
		t.Fatalf("state file mutated: err=%v body=%q", err, after)
	}
}

func migrationMeeting(key string) meeting.Meeting {
	return meeting.Meeting{Key: key, AccountLabel: "alpha", CalendarID: "cal", EventID: "event", Summary: "meeting", Start: time.Now().Add(time.Hour), End: time.Now().Add(2 * time.Hour), URL: "https://zoom.us/j/123"}
}

func TestClosePendingRetryFieldsValidateAsAPair(t *testing.T) {
	item := migrationMeeting("key")
	base := OccurrenceState{Meeting: item, Phase: PhaseClosePending, NotificationID: 7, CloseReason: CloseDeleted}
	for _, invalid := range []OccurrenceState{
		func() OccurrenceState { value := base; value.Attempt = 1; return value }(),
		func() OccurrenceState { value := base; value.NotBefore = time.Now(); return value }(),
	} {
		if err := invalid.Validate(); err == nil {
			t.Fatalf("invalid close retry passed validation: %#v", invalid)
		}
	}
	base.Attempt = 1
	base.NotBefore = time.Now()
	if err := base.Validate(); err != nil {
		t.Fatalf("valid close retry rejected: %v", err)
	}
}
