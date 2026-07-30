package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestLoopAcknowledgesDeliveredNotificationOnlyAfterSave(t *testing.T) {
	now := time.Now()
	m := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[m.Key] = storage.OccurrenceState{Meeting: m, Phase: storage.PhaseNotifyPending, NotifyRevision: 1}
	loop := NewLoop(&spyStore{state: state}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	ack := make(chan notifications.DeliveryAck, 1)
	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: m.Key, Revision: 1, NotificationID: 9, DeliveryAck: ack}}); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-ack:
		if !got.Persisted {
			t.Fatalf("negative acknowledgement: %v", got.Err)
		}
	case <-time.After(time.Second):
		t.Fatal("missing acknowledgement")
	}
	cancel()
	<-done
}
