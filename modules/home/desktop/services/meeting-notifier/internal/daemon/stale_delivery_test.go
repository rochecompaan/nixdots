package daemon

import (
	"context"
	"errors"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"testing"
	"time"
)

func TestStaleDeliveryIsNegativeAcknowledged(t *testing.T) {
	store := &spyStore{state: storage.NewState()}
	loop := NewLoop(store, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	ack := make(chan notifications.DeliveryAck, 1)
	complete := make(chan error, 1)
	complete <- errors.New("closed")
	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: time.Now(), Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: "gone", Revision: 1, NotificationID: 1, DeliveryAck: ack, Completion: complete}}); err != nil {
		t.Fatal(err)
	}
	got := <-ack
	if got.Persisted {
		t.Fatal("stale delivery acknowledged")
	}
	if err := <-done; err == nil {
		t.Fatal("loop accepted stale delivery")
	}
}
