package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestRuntimeConfiguredLeadControlsStartupDueCheck(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(10 * time.Minute))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseScheduled}
	policy, err := NewPolicy(15*time.Minute, []string{"zoom.us"})
	if err != nil {
		t.Fatal(err)
	}
	runtime := NewRuntime(RuntimeConfig{Store: &spyStore{state: state}, Policy: policy})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runtime.Run(ctx) }()

	select {
	case <-runtime.ActivityCommands:
	case <-time.After(time.Second):
		t.Fatal("configured lead time did not schedule activity")
	}
	cancel()
	<-done
}

func TestConfiguredLeadControlsActivityAndReconciliation(t *testing.T) {
	now := time.Date(2025, 1, 2, 10, 0, 0, 0, time.UTC)
	policy, err := NewPolicy(15*time.Minute, []string{"zoom.us"})
	if err != nil {
		t.Fatal(err)
	}
	inside := testMeeting(now.Add(10 * time.Minute))
	state := storage.NewState()
	state.Occurrences[inside.Key] = storage.OccurrenceState{Meeting: inside, Phase: storage.PhaseScheduled}

	next, effects, err := reduceWithPolicy(state, Event{Kind: TickEvent, At: now}, policy)
	if err != nil || len(effects) != 1 || effects[0].Kind != ActivityEffect {
		t.Fatalf("tick effects=%#v err=%v", effects, err)
	}
	next, effects, err = reduceWithPolicy(next, Event{Kind: ActivityResultEvent, At: now, Activity: &ActivityResult{CheckedAt: now, Result: activity.Result{Eligible: true}}}, policy)
	if err != nil || next.Occurrences[inside.Key].Phase != storage.PhaseNotifyPending || len(effects) != 1 || effects[0].Kind != NotifyEffect {
		t.Fatalf("activity occurrence=%#v effects=%#v err=%v", next.Occurrences[inside.Key], effects, err)
	}

	visible := storage.NewState()
	visible.Occurrences[inside.Key] = storage.OccurrenceState{Meeting: inside, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	movedInside := inside
	movedInside.Start = now.Add(12 * time.Minute)
	next, _, err = reduceWithPolicy(visible, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", FetchedAt: now, Meetings: []meeting.Meeting{movedInside}}}, policy)
	if err != nil || next.Occurrences[inside.Key].Phase != storage.PhaseNotifyPending {
		t.Fatalf("inside-lead occurrence=%#v err=%v", next.Occurrences[inside.Key], err)
	}

	movedOutside := inside
	movedOutside.Start = now.Add(20 * time.Minute)
	next, _, err = reduceWithPolicy(visible, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", FetchedAt: now, Meetings: []meeting.Meeting{movedOutside}}}, policy)
	if err != nil || next.Occurrences[inside.Key].Phase != storage.PhaseClosePending || next.Occurrences[inside.Key].ResumePhase != storage.PhaseScheduled {
		t.Fatalf("outside-lead occurrence=%#v err=%v", next.Occurrences[inside.Key], err)
	}
}

func TestConfiguredAllowedHostsControlActionRevalidationWithoutAliasing(t *testing.T) {
	now := time.Now().UTC()
	allowed := []string{"*.video.example.com"}
	policy, err := NewPolicy(5*time.Minute, allowed)
	if err != nil {
		t.Fatal(err)
	}
	allowed[0] = "attacker.example"
	exported := policy.AllowedHosts()
	exported[0] = "another-attacker.example"
	item := testMeeting(now.Add(time.Minute))
	item.URL = "https://room.video.example.com/join"
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}

	next, effects, err := reduceWithPolicy(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.ActionInvoked, ID: 7, ActionKey: "join"}}}, policy)
	if err != nil || next.Occurrences[item.Key].Phase != storage.PhaseJoinPending || len(effects) != 1 || effects[0].Kind != LaunchEffect {
		t.Fatalf("custom-host action occurrence=%#v effects=%#v err=%v", next.Occurrences[item.Key], effects, err)
	}

	item.URL = "https://video.example.com/join"
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	next, effects, err = reduceWithPolicy(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.ActionInvoked, ID: 7, ActionKey: "join"}}}, policy)
	if err != nil || next.Occurrences[item.Key].Phase != storage.PhaseNotified || len(effects) != 0 {
		t.Fatalf("wildcard apex action occurrence=%#v effects=%#v err=%v", next.Occurrences[item.Key], effects, err)
	}
}
