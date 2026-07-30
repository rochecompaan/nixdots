package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestRuntimeTracksRetryBackoffPerAccount(t *testing.T) {
	runtime := NewRuntime(RuntimeConfig{Accounts: []Account{{Label: "alpha"}, {Label: "sixfeetup"}}})
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	want := []time.Duration{time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 15 * time.Minute}
	for attempt, delay := range want {
		runtime.recordPollResult(PollResult{AccountLabel: "alpha", Err: errors.New("failed")}, now)
		got := runtime.retries["alpha"]
		if got.Attempt != attempt+1 || !got.NextAttempt.Equal(now.Add(delay)) {
			t.Fatalf("attempt %d retry = %#v", attempt+1, got)
		}
	}
	runtime.recordPollResult(PollResult{AccountLabel: "sixfeetup"}, now)
	if _, ok := runtime.retries["alpha"]; !ok {
		t.Fatal("successful account reset another account's retry")
	}
	runtime.recordPollResult(PollResult{AccountLabel: "alpha"}, now)
	if _, ok := runtime.retries["alpha"]; ok {
		t.Fatal("successful account did not reset its retry")
	}
}

func TestFailedPollNeverReconcilesReturnedMeetings(t *testing.T) {
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	old := testMeeting(now.Add(time.Hour))
	state := storage.NewState()
	state.Snapshots[old.AccountLabel] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{old}}
	state.Occurrences[old.Key] = storage.OccurrenceState{Meeting: old, Phase: storage.PhaseScheduled}
	changed := old
	changed.Summary = "must not reconcile"
	next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: old.AccountLabel, FetchedAt: now, Meetings: []meeting.Meeting{changed}, Err: errors.New("failed")}})
	if err != nil {
		t.Fatal(err)
	}
	if next.Snapshots[old.AccountLabel].FetchedAt != state.Snapshots[old.AccountLabel].FetchedAt || next.Occurrences[old.Key].Meeting.Summary != old.Summary {
		t.Fatalf("failed poll reconciled state: %#v", next)
	}
}

type delayedCancelSource struct {
	started chan struct{}
	release chan struct{}
}

func (s *delayedCancelSource) SyncAccount(ctx context.Context, _ string, _ storage.AuthorizationBundle, _, _ time.Time) (PollResult, error) {
	close(s.started)
	<-ctx.Done()
	<-s.release
	return PollResult{}, ctx.Err()
}

func TestRuntimeJoinsWorkerBeforeReturning(t *testing.T) {
	source := &delayedCancelSource{started: make(chan struct{}), release: make(chan struct{})}
	runtime := NewRuntime(RuntimeConfig{
		Store: &spyStore{state: storage.NewState()}, Source: source,
		Accounts: []Account{{Label: "alpha"}}, PollInterval: time.Hour, Horizon: 24 * time.Hour,
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	select {
	case <-source.started:
	case <-time.After(time.Second):
		t.Fatal("poll worker did not start")
	}
	cancel()
	select {
	case err := <-done:
		t.Fatalf("runtime returned before worker exited: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	close(source.release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("runtime did not return after worker exited")
	}
}

type blockingLoadStore struct {
	release chan struct{}
}

func (s *blockingLoadStore) LoadState() (storage.State, error) {
	<-s.release
	return storage.NewState(), nil
}
func (s *blockingLoadStore) SaveState(storage.State) error { return nil }

type producerTransport struct {
	started  chan struct{}
	accepted chan struct{}
}

func (t *producerTransport) Run(ctx context.Context, _ <-chan notifications.Command, events chan<- notifications.Event) error {
	close(t.started)
	select {
	case events <- notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.NotificationClosed, ID: 99}}:
		close(t.accepted)
	case <-ctx.Done():
		return ctx.Err()
	}
	<-ctx.Done()
	return ctx.Err()
}

func TestNotificationProducerIsNotAcceptedByLossyIntermediateBridge(t *testing.T) {
	store := &blockingLoadStore{release: make(chan struct{})}
	transport := &producerTransport{started: make(chan struct{}), accepted: make(chan struct{})}
	runtime := NewRuntime(RuntimeConfig{Store: store, Notifications: transport})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	<-transport.started
	select {
	case <-transport.accepted:
		cancel()
		close(store.release)
		<-done
		t.Fatal("intermediate bridge accepted an event before the owner could receive it")
	case <-time.After(30 * time.Millisecond):
	}
	cancel()
	close(store.release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("runtime did not join canceled producer")
	}
	select {
	case <-transport.accepted:
		t.Fatal("canceled producer event was accepted")
	default:
	}
}
