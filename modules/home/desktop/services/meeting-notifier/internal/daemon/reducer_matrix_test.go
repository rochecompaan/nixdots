package daemon

import (
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestAuthenticationPollWarningIsRateLimitedPerAccount(t *testing.T) {
	now := time.Now().UTC()
	state := storage.NewState()
	failure := &PollError{Kind: PollAuthentication, Err: errors.New("auth")}
	next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", Err: failure}})
	if err != nil || len(effects) != 1 || effects[0].Kind != AuthWarningEffect || len(effects[0].Notification.Request.Actions) != 0 {
		t.Fatalf("%v %#v", err, effects)
	}
	if !next.Health["alpha"].NeedsAuth || next.PendingAuthWarnings["alpha"].Revision == 0 || !next.PendingAuthWarnings["alpha"].CreatedAt.Equal(now) {
		t.Fatalf("warning %#v", next)
	}
	next, _, err = Reduce(next, Event{Kind: PollResultEvent, At: now.Add(time.Hour), Poll: &PollResult{AccountLabel: "alpha", Err: failure}})
	if err != nil || next.PendingAuthWarnings["alpha"].Revision != 1 {
		t.Fatalf("rate limit %#v %v", next, err)
	}
}
func TestRescheduleInsideLeadReplacesExistingNotification(t *testing.T) {
	now := time.Now().UTC()
	old := testMeeting(now.Add(10 * time.Minute))
	state := storage.NewState()
	state.Occurrences[old.Key] = storage.OccurrenceState{Meeting: old, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	changed := old
	changed.Start = now.Add(time.Minute)
	next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", FetchedAt: now, Meetings: []meeting.Meeting{changed}}})
	if err != nil {
		t.Fatal(err)
	}
	if next.Occurrences[old.Key].Phase != storage.PhaseNotifyPending || len(effects) != 1 || effects[0].Notification.Request.ReplacesID != 7 {
		t.Fatalf("%#v %#v", next.Occurrences[old.Key], effects)
	}
}
func TestJoinedTombstonePrunesAtEventEnd(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(-time.Hour))
	item.End = now.Add(-time.Minute)
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseJoined, JoinedAt: now.Add(-time.Hour)}
	next, _, err := Reduce(state, Event{Kind: TickEvent, At: now})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := next.Occurrences[item.Key]; ok {
		t.Fatal("expired joined tombstone retained")
	}
}
func TestReasonSpecificObservationsCloseActiveNotification(t *testing.T) {
	now := time.Now().UTC()
	for _, test := range []struct {
		reason meeting.RemovedReason
		want   storage.CloseReason
	}{{meeting.RemovedCancelled, storage.CloseCancelled}, {meeting.RemovedDeclined, storage.CloseDeclined}, {meeting.RemovedURL, storage.CloseURLRemoved}} {
		item := testMeeting(now.Add(time.Hour))
		state := storage.NewState()
		state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 1, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
		next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", FetchedAt: now, Observations: []meeting.Observation{{Key: item.Key, Reason: test.reason}}}})
		if err != nil || next.Occurrences[item.Key].CloseReason != test.want {
			t.Fatalf("%s %#v %v", test.reason, next.Occurrences[item.Key], err)
		}
	}
}
func TestDismissalRetainsActionUntilExpiry(t *testing.T) {
	now := time.Now()
	item := testMeeting(now.Add(time.Hour))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 3, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	next, _, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.NotificationClosed, ID: 3, Reason: 0}}})
	if err != nil || next.Occurrences[item.Key].Phase != storage.PhaseActionableHistory || next.Occurrences[item.Key].NotificationID != 3 {
		t.Fatalf("%#v %v", next.Occurrences[item.Key], err)
	}
}
