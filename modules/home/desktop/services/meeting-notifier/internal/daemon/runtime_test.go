package daemon

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestRuntimeDrainsJoinPendingOldestOneResultAtATime(t *testing.T) {
	state := storage.NewState()
	now := time.Now().UTC()
	for i := 0; i < 100; i++ {
		item := testMeeting(now.Add(time.Duration(i+1) * time.Minute))
		item.Key = fmt.Sprintf("%03d", i)
		state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseJoinPending, NotificationID: uint32(i + 1), NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now, ResumePhase: storage.PhaseNotified}
	}
	runtime := NewRuntime(RuntimeConfig{Store: &spyStore{state: state}})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()
	first := receiveEffect(t, runtime.LaunchCommands)
	if first.OccurrenceKey != "000" {
		t.Fatalf("first %q", first.OccurrenceKey)
	}
	select {
	case <-runtime.LaunchCommands:
		t.Fatal("more than one launch issued while busy")
	case <-time.After(20 * time.Millisecond):
	}
	if err := runtime.Send(ctx, Event{Kind: LaunchResultEvent, At: now, Launch: &LaunchResult{OccurrenceKey: first.OccurrenceKey, JoinRevision: first.JoinRevision}}); err != nil {
		t.Fatal(err)
	}
	second := receiveEffect(t, runtime.LaunchCommands)
	if second.OccurrenceKey != "001" {
		t.Fatalf("second %q", second.OccurrenceKey)
	}
	cancel()
	<-done
}
func receiveEffect(t *testing.T, c <-chan Effect) Effect {
	t.Helper()
	select {
	case value := <-c:
		return value
	case <-time.After(time.Second):
		t.Fatal("missing command")
		return Effect{}
	}
}
