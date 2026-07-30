package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestStaleLaunchCompletionCannotCompleteReplacementJoin(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(4 * time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), NotifyRevision: 1}

	first, effects, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.ActionInvoked, ID: 7, ActionKey: "join"}}})
	if err != nil {
		t.Fatal(err)
	}
	if len(effects) != 1 || effects[0].Kind != LaunchEffect || effects[0].JoinRevision == 0 {
		t.Fatalf("first launch = %#v", effects)
	}
	firstRevision := effects[0].JoinRevision

	replacement := item
	replacement.URL = "https://zoom.us/j/456"
	replaced, _, err := Reduce(first, Event{Kind: PollResultEvent, At: now.Add(time.Second), Poll: &PollResult{AccountLabel: item.AccountLabel, FetchedAt: now.Add(time.Second), Meetings: []meeting.Meeting{replacement}}})
	if err != nil {
		t.Fatal(err)
	}
	notifyRevision := replaced.Occurrences[item.Key].NotifyRevision
	delivered, _, err := Reduce(replaced, Event{Kind: NotificationEvent, At: now.Add(2 * time.Second), Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: item.Key, Revision: notifyRevision, NotificationID: 7}})
	if err != nil {
		t.Fatal(err)
	}
	second, effects, err := Reduce(delivered, Event{Kind: NotificationEvent, At: now.Add(3 * time.Second), Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.ActionInvoked, ID: 7, ActionKey: "join"}}})
	if err != nil {
		t.Fatal(err)
	}
	if len(effects) != 1 || effects[0].JoinRevision <= firstRevision {
		t.Fatalf("second launch = %#v", effects)
	}
	secondRevision := effects[0].JoinRevision

	stale, _, err := Reduce(second, Event{Kind: LaunchResultEvent, At: now.Add(4 * time.Second), Launch: &LaunchResult{OccurrenceKey: item.Key, AccountLabel: item.AccountLabel, JoinRevision: firstRevision}})
	if err != nil {
		t.Fatal(err)
	}
	if got := stale.Occurrences[item.Key]; got.Phase != storage.PhaseJoinPending || got.JoinRevision != secondRevision {
		t.Fatalf("stale completion changed current join: %#v", got)
	}
	completed, _, err := Reduce(stale, Event{Kind: LaunchResultEvent, At: now.Add(5 * time.Second), Launch: &LaunchResult{OccurrenceKey: item.Key, AccountLabel: item.AccountLabel, JoinRevision: secondRevision}})
	if err != nil || completed.Occurrences[item.Key].Phase != storage.PhaseJoined {
		t.Fatalf("current completion = %#v err=%v", completed.Occurrences[item.Key], err)
	}
}

func TestLauncherWorkerSuppressesParentCancellationResult(t *testing.T) {
	for i := 0; i < 50; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		commands := make(chan Effect, 1)
		events := make(chan Event, 1)
		entered := make(chan struct{})
		launcher := launcherFunc(func(call context.Context, _, _ string) error {
			close(entered)
			<-call.Done()
			return call.Err()
		})
		done := make(chan struct{})
		go func() {
			RunLauncherWorker(ctx, launcher, commands, events)
			close(done)
		}()
		commands <- Effect{Kind: LaunchEffect, OccurrenceKey: "key", AccountLabel: "alpha", URL: "https://zoom.us/j/123", JoinRevision: 9}
		<-entered
		cancel()
		<-done
		select {
		case event := <-events:
			t.Fatalf("shutdown emitted launch completion: %#v", event)
		default:
		}
	}
}

func TestShutdownLeavesJoinPendingReplayableOnRestart(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseJoinPending, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now, ResumePhase: storage.PhaseNotified, JoinRevision: 9}
	store := &spyStore{state: state}
	entered := make(chan struct{})
	first := NewRuntime(RuntimeConfig{Store: store, Launcher: launcherFunc(func(call context.Context, _, _ string) error {
		close(entered)
		<-call.Done()
		return call.Err()
	})})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- first.Run(ctx) }()
	<-entered
	cancel()
	<-done
	store.mu.Lock()
	retained := store.state.Occurrences[item.Key]
	store.mu.Unlock()
	if retained.Phase != storage.PhaseJoinPending || retained.JoinRevision != 9 {
		t.Fatalf("shutdown changed durable join: %#v", retained)
	}

	second := NewRuntime(RuntimeConfig{Store: store})
	restartCtx, restartCancel := context.WithCancel(context.Background())
	restartDone := make(chan error, 1)
	go func() { restartDone <- second.Run(restartCtx) }()
	select {
	case replay := <-second.LaunchCommands:
		if replay.OccurrenceKey != item.Key || replay.JoinRevision != 9 {
			t.Fatalf("replayed launch = %#v", replay)
		}
	case <-time.After(time.Second):
		t.Fatal("durable join was not replayed")
	}
	restartCancel()
	<-restartDone
}

func TestLaunchFailureRequiresExactRevision(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseJoinPending, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now, ResumePhase: storage.PhaseNotified, JoinRevision: 4}
	next, _, err := Reduce(state, Event{Kind: LaunchResultEvent, At: now.Add(time.Second), Launch: &LaunchResult{OccurrenceKey: item.Key, JoinRevision: 3, Err: errors.New("old failure")}})
	if err != nil {
		t.Fatal(err)
	}
	if next.Occurrences[item.Key].Phase != storage.PhaseJoinPending {
		t.Fatalf("stale failure rolled back join: %#v", next.Occurrences[item.Key])
	}
}

type launcherFunc func(context.Context, string, string) error

func (f launcherFunc) Open(ctx context.Context, account, rawURL string) error {
	return f(ctx, account, rawURL)
}
