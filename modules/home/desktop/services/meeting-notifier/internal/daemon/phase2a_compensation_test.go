package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestOwnerCompensationBoundExceedsTransportBoundAndWinsCancellationRace(t *testing.T) {
	if notifications.CompensationCompletionTimeout <= notifications.CompensationTimeout {
		t.Fatalf("owner bound %v must exceed transport bound %v", notifications.CompensationCompletionTimeout, notifications.CompensationTimeout)
	}
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1}
	saveErr, closeErr := errors.New("save"), errors.New("close")
	loop := NewLoop(&failingStore{state: state, err: saveErr}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	ack, completion := make(chan notifications.DeliveryAck, 1), make(chan error, 1)
	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: item.Key, Revision: 1, NotificationID: 8, DeliveryAck: ack, Completion: completion}}); err != nil {
		t.Fatal(err)
	}
	<-ack
	cancel()
	completion <- closeErr
	if err := <-done; !errors.Is(err, saveErr) || !errors.Is(err, closeErr) {
		t.Fatalf("error = %v, want joined save and close errors", err)
	}
}

func TestActionlessDeliveryAcknowledgesWithoutCreatingLifecycleState(t *testing.T) {
	loop := NewLoop(&spyStore{state: storage.NewState()}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	ack := make(chan notifications.DeliveryAck, 1)
	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: time.Now().UTC(), Notification: &notifications.Event{Kind: notifications.NotificationDelivered, DeliveryAck: ack}}); err != nil {
		t.Fatal(err)
	}
	if got := <-ack; !got.Persisted || got.Err != nil {
		t.Fatalf("actionless acknowledgement = %#v", got)
	}
	cancel()
	<-done
}
