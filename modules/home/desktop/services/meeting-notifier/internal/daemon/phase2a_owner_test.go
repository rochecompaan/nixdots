package daemon

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestLoopPublishesCopiedNotificationIndexAndRejectsStaleIDs(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	loop := NewLoop(&spyStore{state: state}, nil)
	started := make(chan struct{})
	loop.start = func(context.Context, storage.State) error { close(started); return nil }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	<-started

	index := loop.NotificationIndex()
	delete(index, 7)
	index[99] = "forged"
	fresh := loop.NotificationIndex()
	if fresh[7] != item.Key {
		t.Fatalf("published index aliased caller mutation: %#v", fresh)
	}
	if _, ok := fresh[99]; ok {
		t.Fatalf("published index accepted forged entry: %#v", fresh)
	}

	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.ActionInvoked, ID: 7, ActionKey: "join"}}}); err != nil {
		t.Fatal(err)
	}
	if err := loop.Send(ctx, Event{Kind: LaunchResultEvent, At: now.Add(time.Second), Launch: &LaunchResult{OccurrenceKey: item.Key, JoinRevision: 1}}); err != nil {
		t.Fatal(err)
	}
	waitProcessed(t, loop, 2)
	if got := loop.NotificationIndex(); len(got) != 0 {
		t.Fatalf("stale ID remained published: %#v", got)
	}
	before := loop.Processed()
	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: now.Add(2 * time.Second), Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.ActionInvoked, ID: 7, ActionKey: "join"}}}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for loop.Processed() == before && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := loop.NotificationIndex(); len(got) != 0 {
		t.Fatalf("stale signal republished ID: %#v", got)
	}
	cancel()
	<-done
}

func waitProcessed(t *testing.T, loop *Loop, want uint64) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for loop.Processed() < want && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := loop.Processed(); got < want {
		t.Fatalf("processed %d, want at least %d", got, want)
	}
}

func TestFailedSaveDoesNotPublishNotificationID(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1}
	store := &failingStore{state: state, err: errors.New("save")}
	loop := NewLoop(store, nil)
	ctx := context.Background()
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	ack := make(chan notifications.DeliveryAck, 1)
	completion := make(chan error, 1)
	completion <- nil
	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: item.Key, Revision: 1, NotificationID: 7, DeliveryAck: ack, Completion: completion}}); err != nil {
		t.Fatal(err)
	}
	<-done
	if index := loop.NotificationIndex(); len(index) != 0 {
		t.Fatalf("failed save published index %#v", index)
	}
}

func TestAuthenticationWarningIsPersistedBeforeOneActionlessDispatch(t *testing.T) {
	now := time.Now().UTC()
	state := storage.NewState()
	failure := &PollError{Kind: PollAuthentication, Err: errors.New("auth")}
	next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", Err: failure}})
	if err != nil {
		t.Fatal(err)
	}
	if next.PendingAuthWarnings["alpha"].Revision != 1 || len(effects) != 1 {
		t.Fatalf("state=%#v effects=%#v", next, effects)
	}
	request := effects[0].Notification.Request
	if len(request.Actions) != 0 {
		t.Fatalf("auth warning actions = %#v", request.Actions)
	}
	next, effects, err = Reduce(next, Event{Kind: PollResultEvent, At: now.Add(time.Hour), Poll: &PollResult{AccountLabel: "alpha", Err: failure}})
	if err != nil || len(effects) != 0 {
		t.Fatalf("rate-limited effects=%#v err=%v", effects, err)
	}
}

func TestAuthenticationWarningSaveFailureDispatchesNothing(t *testing.T) {
	now := time.Now().UTC()
	store := &failingStore{state: storage.NewState(), err: errors.New("save")}
	var mu sync.Mutex
	dispatched := 0
	loop := NewLoop(store, func(context.Context, Effect) error {
		mu.Lock()
		dispatched++
		mu.Unlock()
		return nil
	})
	ctx := context.Background()
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	failure := &PollError{Kind: PollAuthentication, Err: errors.New("auth")}
	if err := loop.Send(ctx, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", Err: failure}}); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, store.err) {
		t.Fatalf("loop error = %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if dispatched != 0 {
		t.Fatalf("dispatched %d effects after failed save", dispatched)
	}
}
