package meeting

import (
	"testing"
	"time"
)

func TestObservationPreservesStableOccurrenceIdentityForRemovedMeeting(t *testing.T) {
	original := time.Date(2025, 1, 1, 10, 0, 0, 0, time.UTC)
	key, err := OccurrenceKey("alpha", "calendar", "event", "series", original)
	if err != nil {
		t.Fatal(err)
	}
	observation, err := NewObservation("alpha", "calendar", "event", "series", original, RemovedCancelled)
	if err != nil {
		t.Fatal(err)
	}
	if observation.Key != key || observation.Reason != RemovedCancelled {
		t.Fatalf("observation = %#v", observation)
	}
}

func TestObservationRejectsUnknownReason(t *testing.T) {
	_, err := NewObservation("alpha", "calendar", "event", "", time.Time{}, RemovedReason("unknown"))
	if err == nil {
		t.Fatal("accepted unknown reason")
	}
}

func TestClassifyCandidateRetainsRemovalReason(t *testing.T) {
	candidate := Candidate{AccountLabel: "alpha", CalendarID: "calendar", EventID: "event", Start: time.Now(), Cancelled: true}
	_, observation, err := ClassifyCandidate(candidate, []string{"zoom.us"})
	if err != nil || observation.Reason != RemovedCancelled {
		t.Fatalf("got %#v %v", observation, err)
	}
	candidate.Cancelled = false
	candidate.Declined = true
	_, observation, err = ClassifyCandidate(candidate, []string{"zoom.us"})
	if err != nil || observation.Reason != RemovedDeclined {
		t.Fatalf("got %#v %v", observation, err)
	}
}
