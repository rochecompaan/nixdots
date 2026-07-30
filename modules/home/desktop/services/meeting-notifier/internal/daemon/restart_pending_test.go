package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestRuntimeRestartPersistsPostStartPendingCleanup(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(-time.Minute))
	item.End = now.Add(time.Hour)
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now.Add(time.Minute), Attempt: 1}
	store := &spyStore{state: state}
	runtime := NewRuntime(RuntimeConfig{Store: store})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		store.mu.Lock()
		_, exists := store.state.Occurrences[item.Key]
		saves := store.saves
		store.mu.Unlock()
		if !exists && saves > 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	store.mu.Lock()
	_, exists := store.state.Occurrences[item.Key]
	saves := store.saves
	store.mu.Unlock()
	if exists || saves == 0 {
		cancel()
		<-done
		t.Fatalf("restart did not durably clean pending work: exists=%v saves=%d", exists, saves)
	}
	select {
	case command := <-runtime.NotificationCommands:
		t.Fatalf("restart dispatched post-start notification: %#v", command)
	default:
	}
	cancel()
	<-done
}

func TestRuntimeRestartClosesPostStartReplacement(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(-time.Minute))
	item.End = now.Add(time.Hour)
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotificationID: 19, NotifyRevision: 2, NotBefore: now.Add(time.Minute), Attempt: 1}
	store := &spyStore{state: state}
	runtime := NewRuntime(RuntimeConfig{Store: store})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	var command notifications.Command
	select {
	case command = <-runtime.NotificationCommands:
	case <-time.After(time.Second):
		cancel()
		<-done
		t.Fatal("restart did not dispatch replacement close")
	}
	if command.Kind != notifications.CloseCommand || command.NotificationID != 19 {
		cancel()
		<-done
		t.Fatalf("restart command = %#v", command)
	}
	store.mu.Lock()
	got := store.state.Occurrences[item.Key]
	saves := store.saves
	store.mu.Unlock()
	if got.Phase != storage.PhaseClosePending || saves == 0 {
		cancel()
		<-done
		t.Fatalf("replacement cleanup not durable: %#v saves=%d", got, saves)
	}
	cancel()
	<-done
}

func TestRuntimeRestartPreservesCloseRetryBackoff(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Hour))
	state := storage.NewState()
	notBefore := now.Add(time.Hour)
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseClosePending, NotificationID: 23, CloseReason: storage.CloseDeleted, Attempt: 2, NotBefore: notBefore}
	runtime := NewRuntime(RuntimeConfig{Store: &spyStore{state: state}})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	select {
	case command := <-runtime.NotificationCommands:
		cancel()
		<-done
		t.Fatalf("restart ignored close backoff: %#v", command)
	case <-time.After(20 * time.Millisecond):
	}
	if err := runtime.Send(ctx, Event{Kind: TickEvent, At: notBefore}); err != nil {
		cancel()
		<-done
		t.Fatal(err)
	}
	select {
	case command := <-runtime.NotificationCommands:
		if command.Kind != notifications.CloseCommand || command.NotificationID != 23 {
			t.Fatalf("retry command = %#v", command)
		}
	case <-time.After(time.Second):
		t.Fatal("due close retry was not dispatched")
	}
	cancel()
	<-done
}
