package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type sourceFake struct {
	deadline time.Duration
	result   PollResult
}

func (s *sourceFake) SyncAccount(ctx context.Context, label string, _ storage.AuthorizationBundle, _, _ time.Time) (PollResult, error) {
	deadline, _ := ctx.Deadline()
	s.deadline = time.Until(deadline)
	return s.result, nil
}
func TestPollWorkerUsesThirtySecondDeadlineAndCopiesSuccessfulResult(t *testing.T) {
	item := testMeeting(time.Now().Add(time.Hour))
	source := &sourceFake{result: PollResult{Meetings: []meeting.Meeting{item}}}
	commands := make(chan PollCommand, 1)
	events := make(chan Event)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go RunPollWorker(ctx, source, commands, events)
	commands <- PollCommand{AccountLabel: "alpha", Bundle: storage.AuthorizationBundle{}}
	select {
	case event := <-events:
		source.result.Meetings[0].Summary = "changed"
		if event.Poll.Meetings[0].Summary == "changed" {
			t.Fatal("event retained worker slice")
		}
	case <-time.After(time.Second):
		t.Fatal("no poll result")
	}
	if source.deadline < 29*time.Second || source.deadline > 30*time.Second {
		t.Fatalf("deadline %s", source.deadline)
	}
}
