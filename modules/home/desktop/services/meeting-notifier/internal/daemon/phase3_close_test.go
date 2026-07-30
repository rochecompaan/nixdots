package daemon

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type closingActivity struct {
	mu       sync.Mutex
	returned bool
	closed   bool
	err      error
}

func (a *closingActivity) Current(ctx context.Context) (activity.Result, error) {
	<-ctx.Done()
	a.mu.Lock()
	a.returned = true
	a.mu.Unlock()
	return activity.Result{}, ctx.Err()
}

func (a *closingActivity) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.returned {
		return errors.New("closed before activity worker returned")
	}
	a.closed = true
	return a.err
}

func TestRuntimeJoinsActivityWorkerThenReturnsCloseError(t *testing.T) {
	closeErr := errors.New("close logind")
	reader := &closingActivity{err: closeErr}
	state := storage.NewState()
	item := testMeeting(time.Now().UTC().Add(time.Minute))
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseScheduled}
	runtime := NewRuntime(RuntimeConfig{Store: &spyStore{state: state}, Activity: reader})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	time.Sleep(20 * time.Millisecond)
	cancel()
	err := <-done
	if !errors.Is(err, closeErr) {
		t.Fatalf("runtime error %v does not include close error", err)
	}
	reader.mu.Lock()
	defer reader.mu.Unlock()
	if !reader.closed {
		t.Fatal("activity reader was not closed")
	}
}
