package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
)

type activityFake struct{ seen time.Duration }

func (f *activityFake) Current(ctx context.Context) (activity.Result, error) {
	deadline, _ := ctx.Deadline()
	f.seen = time.Until(deadline)
	return activity.Result{Eligible: true}, nil
}
func TestActivityWorkerUsesFiveSecondDeadlineAndBlockingDelivery(t *testing.T) {
	fake := &activityFake{}
	commands := make(chan struct{}, 1)
	events := make(chan Event)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go RunActivityWorker(ctx, fake, commands, events)
	commands <- struct{}{}
	select {
	case <-events:
	case <-time.After(time.Second):
		t.Fatal("worker did not deliver")
	}
	if fake.seen < 4*time.Second || fake.seen > 5*time.Second {
		t.Fatalf("deadline %s", fake.seen)
	}
}
