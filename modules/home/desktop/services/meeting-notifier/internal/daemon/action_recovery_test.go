package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestInvalidStoredURLNeverQueuesLaunch(t *testing.T) {
	now := time.Now()
	item := testMeeting(now.Add(time.Hour))
	item.URL = "https://evil.example/join"
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 1, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	next, effects, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.ActionInvoked, ID: 1, ActionKey: "join"}}})
	if err != nil || next.Occurrences[item.Key].Phase != storage.PhaseNotified || len(effects) != 0 {
		t.Fatalf("%#v %#v %v", next.Occurrences[item.Key], effects, err)
	}
}
func TestRuntimeRecoveryStartsOldestNotifyBeforeEffects(t *testing.T) {
	now := time.Now()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now}
	runtime := NewRuntime(RuntimeConfig{Store: &spyStore{state: state}})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	command := receiveNotification(t, runtime.NotificationCommands)
	if command.OccurrenceKey != item.Key {
		t.Fatalf("%#v", command)
	}
	cancel()
	<-done
}
