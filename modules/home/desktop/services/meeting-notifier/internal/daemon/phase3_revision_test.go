package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestBlockedNotifyMetadataChangeRejectsOldDelivery(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now}
	store := &spyStore{state: state}
	loop := NewLoop(store, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()

	changed := item
	changed.Summary = "changed while notify was blocked"
	if err := loop.Send(ctx, Event{Kind: PollResultEvent, At: now.Add(time.Second), Poll: &PollResult{AccountLabel: item.AccountLabel, FetchedAt: now.Add(time.Second), Meetings: []meeting.Meeting{changed}}}); err != nil {
		t.Fatal(err)
	}
	ack := make(chan notifications.DeliveryAck, 1)
	completion := make(chan error, 1)
	completion <- nil
	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: now.Add(2 * time.Second), Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: item.Key, Revision: 1, NotificationID: 41, DeliveryAck: ack, Completion: completion}}); err != nil {
		t.Fatal(err)
	}
	if got := <-ack; got.Persisted {
		t.Fatal("old semantic notification delivery was accepted after metadata changed")
	}
	if err := <-done; err == nil {
		t.Fatal("mismatched delivery did not terminate for bounded compensation")
	}
	store.mu.Lock()
	defer store.mu.Unlock()
	if got := store.state.Occurrences[item.Key]; got.Phase != storage.PhaseNotifyPending || got.Meeting.Summary != changed.Summary {
		t.Fatalf("current durable work was not recoverable: %#v", got)
	}
	cancel()
}

func TestNotifyDeliveryRequiresExactRevisionAndPreservesCurrentWork(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotBefore: now, NotifyRevision: 2}
	for name, event := range map[string]notifications.Event{
		"old revision":       {Kind: notifications.NotificationDelivered, OccurrenceKey: item.Key, Revision: 1, NotificationID: 9},
		"matching revision":  {Kind: notifications.NotificationDelivered, OccurrenceKey: item.Key, Revision: 2, NotificationID: 9},
		"removed occurrence": {Kind: notifications.NotificationDelivered, OccurrenceKey: "gone", Revision: 2, NotificationID: 9},
	} {
		t.Run(name, func(t *testing.T) {
			next, _, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &event})
			if err != nil {
				t.Fatal(err)
			}
			got := next.Occurrences[item.Key]
			if name == "matching revision" {
				if got.Phase != storage.PhaseNotified || got.NotificationID != 9 {
					t.Fatalf("matching delivery was not accepted: %#v", got)
				}
			} else if got.Phase != storage.PhaseNotifyPending || got.NotifyRevision != 2 {
				t.Fatalf("mismatch changed recoverable work: %#v", got)
			}
		})
	}
}

func TestBlockedNotifyInvalidationNegativeAcksOutsideLeadAndRemoval(t *testing.T) {
	now := time.Now().UTC()
	for name, poll := range map[string]PollResult{
		"outside lead reschedule": func() PollResult {
			item := testMeeting(now.Add(30 * time.Minute))
			return PollResult{AccountLabel: item.AccountLabel, FetchedAt: now, Meetings: []meeting.Meeting{item}}
		}(),
		"cancellation": {AccountLabel: "alpha", FetchedAt: now, Observations: []meeting.Observation{{Key: "key", Reason: meeting.RemovedCancelled}}},
	} {
		t.Run(name, func(t *testing.T) {
			item := testMeeting(now.Add(time.Minute))
			state := storage.NewState()
			state.Snapshots[item.AccountLabel] = storage.Snapshot{Meetings: []meeting.Meeting{item}}
			state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now}
			store := &spyStore{state: state}
			loop := NewLoop(store, nil)
			ctx := context.Background()
			done := make(chan error, 1)
			go func() { done <- loop.Run(ctx) }()
			if err := loop.Send(ctx, Event{Kind: PollResultEvent, At: now, Poll: &poll}); err != nil {
				t.Fatal(err)
			}
			ack, completion := make(chan notifications.DeliveryAck, 1), make(chan error, 1)
			completion <- nil
			if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: now.Add(time.Second), Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: item.Key, Revision: 1, NotificationID: 7, DeliveryAck: ack, Completion: completion}}); err != nil {
				t.Fatal(err)
			}
			if got := <-ack; got.Persisted {
				t.Fatalf("invalidated notify delivery was accepted: %#v", got)
			}
			if err := <-done; err == nil {
				t.Fatal("stale delivery did not await compensation and terminate")
			}
		})
	}
}
