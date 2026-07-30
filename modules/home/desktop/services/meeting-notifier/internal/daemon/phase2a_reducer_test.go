package daemon

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestReduceRejectsZeroEventTimeWithoutReadingClock(t *testing.T) {
	_, _, err := Reduce(storage.NewState(), Event{Kind: TickEvent})
	var invalid *InvalidEventError
	if !errors.As(err, &invalid) || invalid.Field != "at" {
		t.Fatalf("error = %v, want typed event timestamp error", err)
	}
}

func TestPendingWorkUsesStableKeyTieBreak(t *testing.T) {
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	state := storage.NewState()
	for _, key := range []string{"z-key", "a-key"} {
		item := testMeeting(now.Add(time.Minute))
		item.Key = key
		state.Occurrences[key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1, NotBefore: now}
	}
	for i := 0; i < 50; i++ {
		effects := pendingEffects(state, now)
		if len(effects) == 0 || effects[0].OccurrenceKey != "a-key" {
			t.Fatalf("iteration %d selected %#v", i, effects)
		}
	}
}

func TestQueuedJoinRemovalInvalidatesLaunchForEveryReason(t *testing.T) {
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name   string
		reason meeting.RemovedReason
		want   storage.CloseReason
	}{
		{"cancelled", meeting.RemovedCancelled, storage.CloseCancelled},
		{"declined", meeting.RemovedDeclined, storage.CloseDeclined},
		{"url removed", meeting.RemovedURL, storage.CloseURLRemoved},
	} {
		t.Run(tc.name, func(t *testing.T) {
			item := testMeeting(now.Add(time.Minute))
			state := joinPendingState(item, now)
			next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{
				AccountLabel: item.AccountLabel,
				FetchedAt:    now,
				Observations: []meeting.Observation{{Key: item.Key, Reason: tc.reason}},
			}})
			if err != nil {
				t.Fatal(err)
			}
			o := next.Occurrences[item.Key]
			if o.Phase != storage.PhaseClosePending || o.CloseReason != tc.want {
				t.Fatalf("occurrence = %#v", o)
			}
			for _, effect := range effects {
				if effect.Kind == LaunchEffect && effect.OccurrenceKey == item.Key {
					t.Fatalf("stale launch queued: %#v", effects)
				}
			}
		})
	}
}

func TestQueuedJoinMissingFromSuccessfulPollIsDeletedBeforeLaunch(t *testing.T) {
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(time.Minute))
	state := joinPendingState(item, now)
	state.Snapshots[item.AccountLabel] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{item}}
	next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: item.AccountLabel, FetchedAt: now}})
	if err != nil {
		t.Fatal(err)
	}
	if o := next.Occurrences[item.Key]; o.Phase != storage.PhaseClosePending || o.CloseReason != storage.CloseDeleted {
		t.Fatalf("occurrence = %#v", o)
	}
	for _, effect := range effects {
		if effect.Kind == LaunchEffect && effect.OccurrenceKey == item.Key {
			t.Fatalf("stale launch queued: %#v", effects)
		}
	}
}

func TestQueuedJoinOutsideLeadRescheduleClosesThenResumesScheduled(t *testing.T) {
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(time.Minute))
	state := joinPendingState(item, now)
	changed := item
	changed.Start = now.Add(time.Hour)
	changed.End = changed.Start.Add(time.Hour)
	next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: item.AccountLabel, FetchedAt: now, Meetings: []meeting.Meeting{changed}}})
	if err != nil {
		t.Fatal(err)
	}
	o := next.Occurrences[item.Key]
	if o.Phase != storage.PhaseClosePending || o.CloseReason != storage.CloseRescheduled || o.ResumePhase != storage.PhaseScheduled {
		t.Fatalf("reschedule = %#v", o)
	}
	if len(effects) == 0 || effects[0].Kind != CloseEffect {
		t.Fatalf("effects = %#v", effects)
	}
}

func TestJoinedTombstoneSurvivesRemovalUntilFallbackExpiry(t *testing.T) {
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(-time.Hour))
	item.End = time.Time{}
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseJoined, JoinedAt: now.Add(-time.Hour)}
	next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: item.AccountLabel, FetchedAt: now, Observations: []meeting.Observation{{Key: item.Key, Reason: meeting.RemovedCancelled}}}})
	if err != nil {
		t.Fatal(err)
	}
	if next.Occurrences[item.Key].Phase != storage.PhaseJoined {
		t.Fatalf("joined tombstone changed: %#v", next.Occurrences[item.Key])
	}
	next, _, err = Reduce(next, Event{Kind: TickEvent, At: item.Start.Add(2*time.Hour - time.Nanosecond)})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := next.Occurrences[item.Key]; !ok {
		t.Fatal("joined tombstone pruned before fallback expiry")
	}
	next, _, err = Reduce(next, Event{Kind: TickEvent, At: item.Start.Add(2 * time.Hour)})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := next.Occurrences[item.Key]; ok {
		t.Fatal("joined tombstone retained at fallback expiry")
	}
}

func TestTickExpiresVisibleNotificationThroughCloseExpired(t *testing.T) {
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(-2 * time.Hour))
	item.End = now
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 9, NotifiedAt: now.Add(-time.Hour), ActionExpiresAt: now.Add(time.Hour)}
	next, effects, err := Reduce(state, Event{Kind: TickEvent, At: now})
	if err != nil {
		t.Fatal(err)
	}
	o := next.Occurrences[item.Key]
	if o.Phase != storage.PhaseClosePending || o.CloseReason != storage.CloseExpired {
		t.Fatalf("occurrence = %#v", o)
	}
	if len(effects) == 0 || effects[0].Kind != CloseEffect {
		t.Fatalf("effects = %#v", effects)
	}
}

func TestVisibleFieldChangesReplaceNotificationInsideLead(t *testing.T) {
	now := time.Date(2025, 2, 3, 12, 0, 0, 0, time.UTC)
	base := testMeeting(now.Add(time.Minute))
	changes := map[string]func(*meeting.Meeting){
		"title":   func(m *meeting.Meeting) { m.Summary = "updated" },
		"end":     func(m *meeting.Meeting) { m.End = m.End.Add(time.Minute) },
		"url":     func(m *meeting.Meeting) { m.URL = "https://meet.google.com/abc-defg-hij" },
		"account": func(m *meeting.Meeting) { m.AccountLabel = "sixfeetup" },
	}
	for name, mutate := range changes {
		t.Run(name, func(t *testing.T) {
			state := storage.NewState()
			state.Occurrences[base.Key] = storage.OccurrenceState{Meeting: base, Phase: storage.PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
			changed := base
			mutate(&changed)
			next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: base.AccountLabel, FetchedAt: now, Meetings: []meeting.Meeting{changed}}})
			if err != nil {
				t.Fatal(err)
			}
			o := next.Occurrences[base.Key]
			if o.Phase != storage.PhaseNotifyPending || o.NotificationID != 7 || len(effects) == 0 || effects[0].Notification.Request.ReplacesID != 7 {
				t.Fatalf("occurrence=%#v effects=%#v", o, effects)
			}
		})
	}
}

func TestMeetingNotificationBodyContainsOnlyTrustedContext(t *testing.T) {
	start := time.Date(2025, 2, 3, 12, 34, 0, 0, time.FixedZone("trusted-zone", -5*60*60))
	item := testMeeting(start)
	item.Summary = "Planning"
	item.URL = "https://zoom.us/j/123?secret=sentinel"
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotifyPending, NotifyRevision: 1}
	_, effects, err := Reduce(state, Event{Kind: TickEvent, At: start.Add(-time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	var request notifications.Request
	for _, effect := range effects {
		if effect.Kind == NotifyEffect {
			request = effect.Notification.Request
		}
	}
	if !strings.Contains(request.Body, item.AccountLabel) || !strings.Contains(request.Body, start.Local().Format("Mon Jan 2, 3:04 PM MST")) {
		t.Fatalf("body = %q", request.Body)
	}
	for _, forbidden := range []string{"sentinel", item.URL, "Description"} {
		if strings.Contains(request.Body, forbidden) {
			t.Fatalf("body leaked %q: %q", forbidden, request.Body)
		}
	}
}

func joinPendingState(item meeting.Meeting, now time.Time) storage.State {
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{
		Meeting: item, Phase: storage.PhaseJoinPending, NotificationID: 7,
		NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now,
		ResumePhase: storage.PhaseNotified,
	}
	return state
}
