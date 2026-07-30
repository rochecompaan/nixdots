package daemon

import (
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

const meetingFallbackLifetime = 2 * time.Hour

func prune(state *storage.State, at time.Time) {
	for key, occurrence := range state.Occurrences {
		switch occurrence.Phase {
		case storage.PhaseScheduled, storage.PhaseNotifyPending:
			if meetingExpired(occurrence, at) {
				delete(state.Occurrences, key)
			}
		case storage.PhaseNotified:
			if meetingExpired(occurrence, at) || !occurrence.ActionExpiresAt.After(at) {
				beginClose(&occurrence, storage.CloseExpired, "")
				state.Occurrences[key] = occurrence
			}
		case storage.PhaseActionableHistory:
			if !occurrence.ActionExpiresAt.After(at) {
				delete(state.Occurrences, key)
			}
		case storage.PhaseJoinPending:
			if meetingExpired(occurrence, at) || !occurrence.ActionExpiresAt.After(at) {
				beginClose(&occurrence, storage.CloseExpired, "")
				state.Occurrences[key] = occurrence
			}
		case storage.PhaseJoined:
			if meetingExpired(occurrence, at) {
				delete(state.Occurrences, key)
			}
		}
	}
}

func expireNotifyPending(state *storage.State, at time.Time) {
	for key, occurrence := range state.Occurrences {
		if occurrence.Phase != storage.PhaseNotifyPending || occurrence.Meeting.Start.After(at) {
			continue
		}
		if occurrence.NotificationID == 0 {
			delete(state.Occurrences, key)
			continue
		}
		beginClose(&occurrence, storage.CloseExpired, "")
		state.Occurrences[key] = occurrence
	}
}

func meetingExpired(occurrence storage.OccurrenceState, at time.Time) bool {
	expires := occurrence.Meeting.End
	if expires.IsZero() {
		expires = occurrence.Meeting.Start.Add(meetingFallbackLifetime)
	}
	return !expires.After(at)
}
