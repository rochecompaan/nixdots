package daemon

import (
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestRescheduleOutsideLeadClosesBeforeScheduledResume(t *testing.T) {
	now := time.Now()
	old := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[old.Key] = storage.OccurrenceState{Meeting: old, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	changed := old
	changed.Start = now.Add(time.Hour)
	next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", FetchedAt: now, Meetings: []meeting.Meeting{changed}}})
	if err != nil || next.Occurrences[old.Key].Phase != storage.PhaseClosePending || len(effects) != 1 || effects[0].Kind != CloseEffect {
		t.Fatalf("%#v %#v %v", next.Occurrences[old.Key], effects, err)
	}
	next, _, err = Reduce(next, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationCommandCompleted, OccurrenceKey: old.Key}})
	if err != nil || next.Occurrences[old.Key].Phase != storage.PhaseScheduled {
		t.Fatalf("%#v %v", next.Occurrences[old.Key], err)
	}
}
func TestAmbiguousNotifyFailureRetainsDurableRetry(t *testing.T) {
	now := time.Now()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now}
	next, effects, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationFailed, OccurrenceKey: item.Key, Revision: 1, Err: errors.New("ambiguous")}})
	o := next.Occurrences[item.Key]
	if err != nil || o.Phase != storage.PhaseNotifyPending || o.Attempt != 1 || !o.NotBefore.After(now) || len(effects) != 0 {
		t.Fatalf("%#v %#v %v", o, effects, err)
	}
}
