package daemon

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type spyStore struct {
	mu                              sync.Mutex
	state                           storage.State
	loads, saves, active, maxActive int
}

func (s *spyStore) LoadState() (storage.State, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loads++
	return s.state, nil
}
func (s *spyStore) SaveState(state storage.State) error {
	s.mu.Lock()
	s.active++
	if s.active > s.maxActive {
		s.maxActive = s.active
	}
	s.state = state
	s.saves++
	s.active--
	s.mu.Unlock()
	return nil
}

func TestLoopLoadsOnceSerializesEventsAndSavesBeforeDispatch(t *testing.T) {
	initial := storage.NewState()
	loop := NewLoop(&spyStore{state: initial}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- loop.Run(ctx) }()
	for i := 0; i < 20; i++ {
		if err := loop.Send(ctx, Event{Kind: PollResultEvent, At: time.Now(), Poll: &PollResult{AccountLabel: "alpha", FetchedAt: time.Now().Add(time.Duration(i) * time.Nanosecond)}}); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.Now().Add(time.Second)
	for loop.Processed() < 20 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if loop.Processed() != 20 {
		t.Fatalf("processed %d", loop.Processed())
	}
	cancel()
	<-done
	loop.store.(*spyStore).mu.Lock()
	defer loop.store.(*spyStore).mu.Unlock()
	store := loop.store.(*spyStore)
	if store.loads != 1 || store.maxActive != 1 || store.saves != 20 {
		t.Fatalf("store loads=%d saves=%d max=%d", store.loads, store.saves, store.maxActive)
	}
}

func TestSendBackpressuresUntilCancellation(t *testing.T) {
	loop := NewLoop(&spyStore{state: storage.NewState()}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	for i := 0; i < 2; i++ { // no loop running: first blocks on unbuffered ingress
		if i == 0 {
			go func() { _ = loop.Send(ctx, Event{Kind: TickEvent}) }()
			time.Sleep(10 * time.Millisecond)
		}
	}
	cancel()
}
