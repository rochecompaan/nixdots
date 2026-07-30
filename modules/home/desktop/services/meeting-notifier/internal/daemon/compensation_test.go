package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type failingStore struct {
	state storage.State
	saves int
	err   error
}

func (s *failingStore) LoadState() (storage.State, error) { return s.state, nil }
func (s *failingStore) SaveState(storage.State) error     { s.saves++; return s.err }
func TestDeliveredSaveFailureNegativeAcksThenJoinsCompensation(t *testing.T) {
	now := time.Now()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1}
	saveErr := errors.New("save")
	closeErr := errors.New("close")
	store := &failingStore{state: state, err: saveErr}
	loop := NewLoop(store, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	ack := make(chan notifications.DeliveryAck, 1)
	completion := make(chan error, 1)
	go func() {
		result := <-ack
		if result.Persisted || !errors.Is(result.Err, saveErr) {
			t.Errorf("ack %#v", result)
		}
		completion <- closeErr
	}()
	if err := loop.Send(ctx, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: item.Key, Revision: 1, NotificationID: 1, DeliveryAck: ack, Completion: completion}}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, saveErr) || !errors.Is(err, closeErr) {
			t.Fatalf("joined error %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("loop did not await completion")
	}
	if store.saves != 1 {
		t.Fatalf("saves %d", store.saves)
	}
}
