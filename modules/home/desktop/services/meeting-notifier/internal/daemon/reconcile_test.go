package daemon

import (
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestSuccessfulPollClassifiesExplicitCancellationAndAbsenceSeparately(t *testing.T) {
	now := time.Now().UTC()
	m := testMeeting(now.Add(time.Minute))
	other := m
	other.Key = "other"
	other.EventID = "other"
	state := storage.NewState()
	for _, item := range []meeting.Meeting{m, other} {
		state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseNotified, NotificationID: map[string]uint32{m.Key: 1, other.Key: 2}[item.Key], NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)}
	}
	state.Snapshots["alpha"] = storage.Snapshot{FetchedAt: now, Meetings: []meeting.Meeting{m, other}}
	next, _, err := Reduce(state, Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: "alpha", FetchedAt: now, Observations: []meeting.Observation{{Key: m.Key, Reason: meeting.RemovedCancelled}}}})
	if err != nil {
		t.Fatal(err)
	}
	if got := next.Occurrences[m.Key].CloseReason; got != storage.CloseCancelled {
		t.Fatalf("cancel reason %s", got)
	}
	if got := next.Occurrences[other.Key].CloseReason; got != storage.CloseDeleted {
		t.Fatalf("absence reason %s", got)
	}
}
