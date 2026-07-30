package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestAuthWarningBusyCrashRestartsFromDurablePendingWork(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now}
	store := &spyStore{state: state}

	first := NewRuntime(RuntimeConfig{Store: store})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- first.Run(ctx) }()
	_ = receiveNotification(t, first.NotificationCommands) // keep notifier busy
	if err := first.Send(ctx, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", Err: &PollError{Kind: PollAuthentication, Err: errors.New("invalid_grant")}}}); err != nil {
		t.Fatal(err)
	}
	waitProcessed(t, first.loop, 1)
	cancel()
	<-done

	second := NewRuntime(RuntimeConfig{Store: store})
	ctx, cancel = context.WithCancel(context.Background())
	done = make(chan error, 1)
	go func() { done <- second.Run(ctx) }()
	ordinary := receiveNotification(t, second.NotificationCommands)
	if ordinary.OccurrenceKey != item.Key {
		t.Fatalf("ordinary command = %#v", ordinary)
	}
	if err := second.Send(ctx, Event{Kind: NotificationEvent, At: now.Add(time.Second), Notification: &notifications.Event{Kind: notifications.NotificationFailed, OccurrenceKey: item.Key, Revision: ordinary.Revision, Err: errors.New("notify failed")}}); err != nil {
		t.Fatal(err)
	}
	warning := receiveNotification(t, second.NotificationCommands)
	if warning.OccurrenceKey != "" || warning.Request.Summary != "Meeting notifier authorization required" {
		t.Fatalf("recovered warning = %#v", warning)
	}
	cancel()
	<-done
}
