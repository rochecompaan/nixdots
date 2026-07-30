package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestRuntimeStartupIndependentlyFillsDueNotifierAndLauncher(t *testing.T) {
	now := time.Now().UTC()
	state := storage.NewState()
	due := testMeeting(now.Add(time.Minute))
	due.Key = "due"
	notify := testMeeting(now.Add(2 * time.Minute))
	notify.Key = "notify"
	join := testMeeting(now.Add(3 * time.Minute))
	join.Key = "join"
	state.Occurrences[due.Key] = storage.OccurrenceState{Meeting: due, Phase: storage.PhaseScheduled}
	state.Occurrences[notify.Key] = storage.OccurrenceState{Meeting: notify, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now}
	state.Occurrences[join.Key] = storage.OccurrenceState{Meeting: join, Phase: storage.PhaseJoinPending, NotificationID: 8, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now, ResumePhase: storage.PhaseNotified}

	runtime := NewRuntime(RuntimeConfig{Store: &spyStore{state: state}})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()

	select {
	case <-runtime.ActivityCommands:
	case <-time.After(time.Second):
		t.Fatal("startup did not schedule due activity")
	}
	if got := receiveNotification(t, runtime.NotificationCommands); got.OccurrenceKey != notify.Key {
		t.Fatalf("notifier command = %#v", got)
	}
	if got := receiveEffect(t, runtime.LaunchCommands); got.OccurrenceKey != join.Key {
		t.Fatalf("launcher command = %#v", got)
	}
	cancel()
	<-done
}

func TestRuntimeIdleActivityResultWaitsForNextSchedulingGeneration(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseScheduled}
	runtime := NewRuntime(RuntimeConfig{Store: &spyStore{state: state}})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	select {
	case <-runtime.ActivityCommands:
	case <-time.After(time.Second):
		t.Fatal("missing startup activity")
	}
	if err := runtime.Send(ctx, Event{Kind: ActivityResultEvent, At: now, Activity: &ActivityResult{CheckedAt: now, Result: activity.Result{}}}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-runtime.ActivityCommands:
		t.Fatal("idle activity result immediately rescheduled a hot-loop check")
	case <-time.After(50 * time.Millisecond):
	}
	if err := runtime.Send(ctx, Event{Kind: TickEvent, At: now.Add(30 * time.Second)}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-runtime.ActivityCommands:
	case <-time.After(time.Second):
		t.Fatal("next tick did not create an activity scheduling generation")
	}
	cancel()
	<-done
}
