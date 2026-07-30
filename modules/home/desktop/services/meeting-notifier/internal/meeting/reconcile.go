package meeting

import (
	"fmt"
	"time"
)

type RemovedReason string

const (
	RemovedCancelled     RemovedReason = "cancelled"
	RemovedDeclined      RemovedReason = "declined"
	RemovedURL           RemovedReason = "url-removed"
	RemovedNonActionable RemovedReason = "non-actionable"
)

type Observation struct {
	Key       string
	Reason    RemovedReason
	Exclusion ExclusionReason
}

func ClassifyCandidate(candidate Candidate, allowedHosts []string) (Meeting, Observation, error) {
	reason := RemovedReason("")
	switch {
	case candidate.Cancelled:
		reason = RemovedCancelled
	case candidate.Declined:
		reason = RemovedDeclined
	}
	if reason != "" {
		observation, err := NewObservation(candidate.AccountLabel, candidate.CalendarID, candidate.EventID, candidate.RecurringEventID, candidate.OriginalStart, reason)
		return Meeting{}, observation, err
	}
	item, exclusion, err := normalizeCandidate(candidate, allowedHosts)
	if err != nil {
		return Meeting{}, Observation{}, err
	}
	if exclusion == "" {
		return item, Observation{}, nil
	}
	key, err := OccurrenceKey(candidate.AccountLabel, candidate.CalendarID, candidate.EventID, candidate.RecurringEventID, candidate.OriginalStart)
	if err != nil {
		return Meeting{}, Observation{}, err
	}
	return Meeting{}, Observation{Key: key, Exclusion: exclusion}, nil
}

func NewObservation(account, calendarID, eventID, recurringEventID string, originalStart time.Time, reason RemovedReason) (Observation, error) {
	switch reason {
	case RemovedCancelled, RemovedDeclined, RemovedURL, RemovedNonActionable:
	default:
		return Observation{}, fmt.Errorf("invalid removed reason %q", reason)
	}
	key, err := OccurrenceKey(account, calendarID, eventID, recurringEventID, originalStart)
	if err != nil {
		return Observation{}, err
	}
	return Observation{Key: key, Reason: reason}, nil
}
