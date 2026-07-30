package daemon

import (
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestNotifyPendingIsNeverDispatchedAtOrAfterStart(t *testing.T) {
	start := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	for _, offset := range []time.Duration{0, time.Second} {
		t.Run(offset.String(), func(t *testing.T) {
			item := testMeeting(start)
			state := storage.NewState()
			state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: start.Add(-time.Minute)}
			next, effects, err := Reduce(state, Event{Kind: TickEvent, At: start.Add(offset)})
			if err != nil {
				t.Fatal(err)
			}
			if _, exists := next.Occurrences[item.Key]; exists {
				t.Fatalf("expired initial delivery retained: %#v", next.Occurrences[item.Key])
			}
			if len(effects) != 0 {
				t.Fatalf("post-start effects = %#v", effects)
			}
		})
	}
}

func TestNotifyPendingReplacementClosesAtStart(t *testing.T) {
	start := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	item := testMeeting(start)
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotificationID: 44, NotifyRevision: 2, NotBefore: start.Add(-time.Minute)}
	next, effects, err := Reduce(state, Event{Kind: TickEvent, At: start})
	if err != nil {
		t.Fatal(err)
	}
	got := next.Occurrences[item.Key]
	if got.Phase != storage.PhaseClosePending || got.NotificationID != 44 {
		t.Fatalf("replacement = %#v", got)
	}
	if len(effects) != 1 || effects[0].Kind != CloseEffect {
		t.Fatalf("effects = %#v", effects)
	}
}

func TestNotifyRetryCrossingStartExpiresInsteadOfRedispatching(t *testing.T) {
	start := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	item := testMeeting(start)
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: start.Add(-time.Second)}
	retried, _, err := Reduce(state, Event{Kind: NotificationEvent, At: start.Add(-time.Second), Notification: &notifications.Event{Kind: notifications.NotificationFailed, OccurrenceKey: item.Key, Revision: 1, Err: errors.New("fast failure")}})
	if err != nil {
		t.Fatal(err)
	}
	if !retried.Occurrences[item.Key].NotBefore.After(start) {
		t.Fatalf("retry did not cross start: %#v", retried.Occurrences[item.Key])
	}
	next, effects, err := Reduce(retried, Event{Kind: TickEvent, At: start})
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := next.Occurrences[item.Key]; exists || len(effects) != 0 {
		t.Fatalf("post-start retry retained: state=%#v effects=%#v", next.Occurrences, effects)
	}
}

func TestNotifyPendingStillDispatchesImmediatelyBeforeStart(t *testing.T) {
	start := time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC)
	item := testMeeting(start)
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: start.Add(-time.Minute)}
	_, effects, err := Reduce(state, Event{Kind: TickEvent, At: start.Add(-time.Nanosecond)})
	if err != nil {
		t.Fatal(err)
	}
	if len(effects) != 1 || effects[0].Kind != NotifyEffect {
		t.Fatalf("effects = %#v", effects)
	}
}

func TestJoinedTombstoneRefreshesMeetingBoundsAcrossPollTickPoll(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	old := testMeeting(now.Add(time.Hour))
	old.End = old.Start.Add(30 * time.Minute)
	moved := old
	moved.Start = now.Add(5 * time.Hour)
	moved.End = moved.Start.Add(30 * time.Minute)
	state := storage.NewState()
	state.Snapshots[old.AccountLabel] = storage.Snapshot{FetchedAt: now, Meetings: []meeting.Meeting{old}}
	state.Occurrences[old.Key] = storage.OccurrenceState{Meeting: old, Phase: storage.PhaseJoined, JoinedAt: now}

	first, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: old.AccountLabel, FetchedAt: now, Meetings: []meeting.Meeting{moved}}})
	if err != nil {
		t.Fatal(err)
	}
	if !first.Occurrences[old.Key].Meeting.Start.Equal(moved.Start) || first.Occurrences[old.Key].Phase != storage.PhaseJoined {
		t.Fatalf("joined tombstone not refreshed: %#v", first.Occurrences[old.Key])
	}
	betweenEnds := old.End.Add(time.Minute)
	second, _, err := Reduce(first, Event{Kind: TickEvent, At: betweenEnds})
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := second.Occurrences[old.Key]; !exists {
		t.Fatal("moved joined tombstone expired at old end")
	}
	third, effects, err := Reduce(second, Event{Kind: PollResultEvent, At: betweenEnds, Poll: &PollResult{AccountLabel: old.AccountLabel, FetchedAt: betweenEnds, Meetings: []meeting.Meeting{moved}}})
	if err != nil {
		t.Fatal(err)
	}
	if third.Occurrences[old.Key].Phase != storage.PhaseJoined || len(effects) != 0 {
		t.Fatalf("joined occurrence recreated: %#v effects=%#v", third.Occurrences[old.Key], effects)
	}
}

func TestCloseFailureBacksOffDurablyAndSuccessResetsRetry(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(time.Hour))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseClosePending, NotificationID: 9, CloseReason: storage.CloseDeleted}
	failed, effects, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationFailed, OccurrenceKey: item.Key, NotificationID: 9, Err: errors.New("dbus down")}})
	if err != nil {
		t.Fatal(err)
	}
	got := failed.Occurrences[item.Key]
	if got.Phase != storage.PhaseClosePending || got.Attempt != 1 || !got.NotBefore.After(now) {
		t.Fatalf("close retry = %#v", got)
	}
	if len(effects) != 0 {
		t.Fatalf("immediate close redispatch = %#v", effects)
	}
	_, before, err := Reduce(failed, Event{Kind: TickEvent, At: got.NotBefore.Add(-time.Nanosecond)})
	if err != nil || len(before) != 0 {
		t.Fatalf("early retry effects=%#v err=%v", before, err)
	}
	_, due, err := Reduce(failed, Event{Kind: TickEvent, At: got.NotBefore})
	if err != nil || len(due) != 1 || due[0].Kind != CloseEffect {
		t.Fatalf("due retry effects=%#v err=%v", due, err)
	}
	completed, _, err := Reduce(failed, Event{Kind: NotificationEvent, At: got.NotBefore, Notification: &notifications.Event{Kind: notifications.NotificationCommandCompleted, OccurrenceKey: item.Key, NotificationID: 9}})
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := completed.Occurrences[item.Key]; exists {
		t.Fatalf("completed close retained: %#v", completed.Occurrences[item.Key])
	}
}

func TestBackedOffCloseDoesNotStarveLaterNotificationWork(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	closing := testMeeting(now.Add(time.Minute))
	closing.Key = "closing"
	notify := testMeeting(now.Add(2 * time.Minute))
	notify.Key = "notify"
	state := storage.NewState()
	state.Occurrences[closing.Key] = storage.OccurrenceState{Meeting: closing, Phase: storage.PhaseClosePending, NotificationID: 9, CloseReason: storage.CloseDeleted, Attempt: 1, NotBefore: now.Add(time.Minute)}
	state.Occurrences[notify.Key] = storage.OccurrenceState{Meeting: notify, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now}
	_, effects, err := Reduce(state, Event{Kind: TickEvent, At: now})
	if err != nil {
		t.Fatal(err)
	}
	if len(effects) != 1 || effects[0].Kind != NotifyEffect || effects[0].OccurrenceKey != notify.Key {
		t.Fatalf("later notification starved: %#v", effects)
	}
}
