package daemon

import (
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestReduceTickThenEligibleActivityPersistsNotifyBeforeEffect(t *testing.T) {
	now := time.Date(2025, 1, 2, 10, 0, 0, 0, time.UTC)
	m := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[m.Key] = storage.OccurrenceState{Meeting: m, Phase: storage.PhaseScheduled}

	next, effects, err := Reduce(state, Event{Kind: TickEvent, At: now})
	if err != nil || len(effects) != 1 || effects[0].Kind != ActivityEffect || next.Occurrences[m.Key].Phase != storage.PhaseScheduled {
		t.Fatalf("tick = %#v, %#v, %v", next, effects, err)
	}
	next, effects, err = Reduce(next, Event{Kind: ActivityResultEvent, At: now, Activity: &ActivityResult{CheckedAt: now, Result: activity.Result{Eligible: true}}})
	if err != nil || len(effects) != 1 || effects[0].Kind != NotifyEffect {
		t.Fatalf("activity = %#v, %v", effects, err)
	}
	got := next.Occurrences[m.Key]
	if got.Phase != storage.PhaseNotifyPending || got.NotBefore != now {
		t.Fatalf("occurrence = %#v", got)
	}
	if err := next.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestReduceDeliveryAndActionQueueJoin(t *testing.T) {
	now := time.Now().UTC()
	m := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[m.Key] = storage.OccurrenceState{Meeting: m, Phase: storage.PhaseNotifyPending, NotifyRevision: 1}
	next, _, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationDelivered, OccurrenceKey: m.Key, Revision: 1, NotificationID: 7}})
	if err != nil {
		t.Fatal(err)
	}
	got := next.Occurrences[m.Key]
	if got.Phase != storage.PhaseNotified || got.NotificationID != 7 {
		t.Fatalf("delivery = %#v", got)
	}
	next, effects, err := Reduce(next, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: notifications.Signal{Kind: notifications.ActionInvoked, ID: 7, ActionKey: "join"}}})
	if err != nil || len(effects) != 1 || effects[0].Kind != LaunchEffect {
		t.Fatalf("action = %#v %v", effects, err)
	}
	if next.Occurrences[m.Key].Phase != storage.PhaseJoinPending {
		t.Fatalf("phase = %s", next.Occurrences[m.Key].Phase)
	}
}

func TestReduceRejectsUnactionableSignals(t *testing.T) {
	now := time.Now().UTC()
	m := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[m.Key] = storage.OccurrenceState{Meeting: m, Phase: storage.PhaseActionableHistory, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	for _, signal := range []notifications.Signal{
		{Kind: notifications.ActionInvoked, ID: 8, ActionKey: "join"},
		{Kind: notifications.ActionInvoked, ID: 7, ActionKey: "other"},
		{Kind: notifications.NotificationClosed, ID: 7},
	} {
		next, effects, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.SignalReceived, Signal: signal}})
		if err != nil || len(effects) != 0 || next.Occurrences[m.Key].Phase != storage.PhaseActionableHistory {
			t.Fatalf("signal %#v: %#v %#v %v", signal, next, effects, err)
		}
	}
}

func TestReduceLaunchFailureResumesAndSuccessCreatesTombstone(t *testing.T) {
	now := time.Now().UTC()
	m := testMeeting(now.Add(time.Minute))
	state := storage.NewState()
	state.Occurrences[m.Key] = storage.OccurrenceState{Meeting: m, Phase: storage.PhaseJoinPending, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now, ResumePhase: storage.PhaseNotified, JoinRevision: 1}
	next, _, err := Reduce(state, Event{Kind: LaunchResultEvent, At: now, Launch: &LaunchResult{OccurrenceKey: m.Key, JoinRevision: 1, Err: errTest{}}})
	if err != nil || next.Occurrences[m.Key].Phase != storage.PhaseNotified {
		t.Fatalf("failure %#v %v", next, err)
	}
	next, _, err = Reduce(state, Event{Kind: LaunchResultEvent, At: now, Launch: &LaunchResult{OccurrenceKey: m.Key, JoinRevision: 1}})
	if err != nil || next.Occurrences[m.Key].Phase != storage.PhaseJoined || next.Occurrences[m.Key].NotificationID != 0 {
		t.Fatalf("success %#v %v", next, err)
	}
}

type errTest struct{}

func (errTest) Error() string { return "test" }
func testMeeting(start time.Time) meeting.Meeting {
	return meeting.Meeting{Key: "key", AccountLabel: "alpha", CalendarID: "cal", EventID: "event", Summary: "meeting", Start: start, End: start.Add(time.Hour), URL: "https://zoom.us/j/123"}
}
