package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestRuntimeTickSchedulesOneActivityThenNotifyAfterResult(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseScheduled}
	store := &spyStore{state: state}
	runtime := NewRuntime(RuntimeConfig{Store: store})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	if err := runtime.Send(ctx, Event{Kind: TickEvent, At: now}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-runtime.ActivityCommands:
	case <-time.After(time.Second):
		t.Fatal("missing activity command")
	}
	if err := runtime.Send(ctx, Event{Kind: ActivityResultEvent, At: now, Activity: &ActivityResult{Result: activity.Result{Eligible: true}}}); err != nil {
		t.Fatal(err)
	}
	command := receiveNotification(t, runtime.NotificationCommands)
	if command.Kind != 1 || command.OccurrenceKey != item.Key {
		t.Fatalf("notification %#v", command)
	}
	cancel()
	<-done
}
func receiveNotification(t *testing.T, c <-chan notifications.Command) notifications.Command {
	t.Helper()
	select {
	case value := <-c:
		return value
	case <-time.After(time.Second):
		t.Fatal("missing notification command")
		return notifications.Command{}
	}
}
