package daemon

import (
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestKnownPresentNonTimedObservationClosesStaleActionability(t *testing.T) {
	now := time.Date(2030, 1, 1, 9, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(time.Hour))
	state := storage.NewState()
	state.Snapshots[item.AccountLabel] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{item}}
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 9, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}

	next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{
		AccountLabel: item.AccountLabel,
		FetchedAt:    now,
		Observations: []meeting.Observation{{Key: item.Key, Exclusion: meeting.ExcludedAllDay}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if got := next.Occurrences[item.Key]; got.Phase != storage.PhaseClosePending || got.CloseReason != storage.CloseReason("non-actionable") {
		t.Fatalf("present exclusion preserved stale actionability: %#v", got)
	}
}

func TestURLExclusionRemovesOnlyKnownMeeting(t *testing.T) {
	now := time.Date(2030, 1, 1, 9, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(time.Hour))
	for name, known := range map[string]bool{"unknown candidate": false, "known URL loss": true} {
		t.Run(name, func(t *testing.T) {
			state := storage.NewState()
			if known {
				state.Snapshots[item.AccountLabel] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{item}}
				state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: 9, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
			}
			next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: item.AccountLabel, FetchedAt: now, Observations: []meeting.Observation{{Key: item.Key, Exclusion: meeting.ExcludedMissingURL}}}})
			if err != nil {
				t.Fatal(err)
			}
			got, exists := next.Occurrences[item.Key]
			if known && (!exists || got.CloseReason != storage.CloseURLRemoved) {
				t.Fatalf("known URL loss = %#v, exists=%v", got, exists)
			}
			if !known && exists {
				t.Fatalf("unknown non-actionable candidate became URL removal: %#v", got)
			}
		})
	}
}

func TestKnownMalformedApprovedURLClosesAsURLRemoved(t *testing.T) {
	now := time.Date(2030, 1, 1, 9, 0, 0, 0, time.UTC)
	item := testMeeting(now.Add(time.Hour))
	state := storage.NewState()
	state.Snapshots[item.AccountLabel] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{item}}
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseActionableHistory, NotificationID: 9, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: item.AccountLabel, FetchedAt: now, Observations: []meeting.Observation{{Key: item.Key, Exclusion: meeting.ExcludedMalformedURL}}}})
	if err != nil {
		t.Fatal(err)
	}
	if got := next.Occurrences[item.Key]; got.Phase != storage.PhaseClosePending || got.CloseReason != storage.CloseURLRemoved {
		t.Fatalf("malformed approved URL preserved stale actionability: %#v", got)
	}
}

func TestKnownNonActionableObservationNeverRetainsActionableOrQueuedWork(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Hour))
	for name, occurrence := range map[string]storage.OccurrenceState{
		"scheduled":          {Meeting: item, Phase: storage.PhaseScheduled},
		"notified":           {Meeting: item, Phase: storage.PhaseNotified, NotificationID: 2, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), NotifyRevision: 1},
		"actionable history": {Meeting: item, Phase: storage.PhaseActionableHistory, NotificationID: 2, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), NotifyRevision: 1},
		"queued join":        {Meeting: item, Phase: storage.PhaseJoinPending, NotificationID: 2, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), NotifyRevision: 1, JoinRequestedAt: now, ResumePhase: storage.PhaseNotified},
	} {
		t.Run(name, func(t *testing.T) {
			state := storage.NewState()
			state.Snapshots[item.AccountLabel] = storage.Snapshot{Meetings: []meeting.Meeting{item}}
			state.Occurrences[item.Key] = occurrence
			next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: item.AccountLabel, FetchedAt: now, Observations: []meeting.Observation{{Key: item.Key, Exclusion: meeting.ExcludedAllDay}}}})
			if err != nil {
				t.Fatal(err)
			}
			got, exists := next.Occurrences[item.Key]
			if occurrence.Phase == storage.PhaseScheduled {
				if exists {
					t.Fatalf("scheduled non-actionable occurrence retained: %#v", got)
				}
				return
			}
			if !exists || got.Phase != storage.PhaseClosePending || got.CloseReason != storage.CloseNonActionable {
				t.Fatalf("non-actionable observation left stale work: %#v", got)
			}
		})
	}
}

func TestPresentSameKeyChangeInfersRescheduleFromStoredFields(t *testing.T) {
	now := time.Date(2030, 1, 1, 9, 0, 0, 0, time.UTC)
	old := testMeeting(now.Add(20 * time.Minute))
	moved := old
	moved.Start = now.Add(40 * time.Minute)
	state := storage.NewState()
	state.Snapshots[old.AccountLabel] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{old}}
	state.Occurrences[old.Key] = storage.OccurrenceState{Meeting: old, Phase: storage.PhaseNotified, NotificationID: 9, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}

	next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: old.AccountLabel, FetchedAt: now, Meetings: []meeting.Meeting{moved}}})
	if err != nil {
		t.Fatal(err)
	}
	got := next.Occurrences[old.Key]
	if got.Phase != storage.PhaseClosePending || got.CloseReason != storage.CloseRescheduled || !got.Meeting.Start.Equal(moved.Start) {
		t.Fatalf("present field change did not infer reschedule: %#v", got)
	}
}

func TestMalformedUnknownObservationRejectsPollBeforeAbsenceReconciliation(t *testing.T) {
	now := time.Now().UTC()
	cached := testMeeting(now.Add(time.Hour))
	tests := []struct {
		name        string
		observation meeting.Observation
		field       string
	}{
		{name: "unknown removed reason", observation: meeting.Observation{Key: "unknown", Reason: meeting.RemovedReason("future-reason")}, field: "observations.reason"},
		{name: "unknown exclusion", observation: meeting.Observation{Key: "unknown", Exclusion: meeting.ExclusionReason("future-exclusion")}, field: "observations.exclusion"},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			state := storage.NewState()
			state.Snapshots[cached.AccountLabel] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{cached}}
			state.Occurrences[cached.Key] = storage.OccurrenceState{Meeting: cached, Phase: storage.PhaseScheduled}

			next, effects, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{
				AccountLabel: cached.AccountLabel,
				FetchedAt:    now,
				Observations: []meeting.Observation{testCase.observation},
			}})
			var invalid *InvalidPollError
			if !errors.As(err, &invalid) || invalid.Field != testCase.field {
				t.Fatalf("error = %T %v", err, err)
			}
			if len(effects) != 0 || !reflect.DeepEqual(next, state) {
				t.Fatalf("malformed poll changed state: next=%#v effects=%#v", next, effects)
			}
		})
	}
}

func TestFailedPollNeverReconcilesAbsence(t *testing.T) {
	now := time.Now().UTC()
	item := testMeeting(now.Add(time.Hour))
	state := storage.NewState()
	state.Snapshots[item.AccountLabel] = storage.Snapshot{FetchedAt: now.Add(-time.Minute), Meetings: []meeting.Meeting{item}}
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseScheduled}
	next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: item.AccountLabel, Err: &PollError{Kind: PollTransient}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := next.Occurrences[item.Key]; !ok || len(next.Snapshots[item.AccountLabel].Meetings) != 1 {
		t.Fatal("failed poll reconciled absence")
	}
}
