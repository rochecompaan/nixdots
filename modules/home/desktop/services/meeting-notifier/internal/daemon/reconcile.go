package daemon

import (
	"fmt"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func reconcile(state *storage.State, poll PollResult, at time.Time, policy Policy) error {
	for _, observation := range poll.Observations {
		if err := validateObservation(observation); err != nil {
			return err
		}
	}
	current := make(map[string]meeting.Meeting, len(poll.Meetings))
	for _, item := range poll.Meetings {
		if item.Key == "" {
			return fmt.Errorf("poll contains meeting without stable key")
		}
		current[item.Key] = item
	}
	previous := state.Snapshots[poll.AccountLabel]
	removed := make(map[string]meeting.RemovedReason, len(poll.Observations))
	present := make(map[string]struct{}, len(current)+len(poll.Observations))
	for key := range current {
		present[key] = struct{}{}
	}
	for _, observation := range poll.Observations {
		present[observation.Key] = struct{}{}
		if observation.Reason != "" {
			removed[observation.Key] = observation.Reason
			continue
		}
		if !knownMeeting(state, previous, observation.Key) {
			continue
		}
		switch observation.Exclusion {
		case meeting.ExcludedMissingURL, meeting.ExcludedUnsupportedURL, meeting.ExcludedMalformedURL:
			removed[observation.Key] = meeting.RemovedURL
		case meeting.ExcludedAllDay, meeting.ExcludedMissingStart:
			removed[observation.Key] = meeting.RemovedNonActionable
		default:
			return fmt.Errorf("poll contains unclassified observation")
		}
	}

	for _, item := range previous.Meetings {
		if _, ok := present[item.Key]; !ok {
			if err := reconcileRemoved(state, item.Key, storage.CloseDeleted); err != nil {
				return err
			}
		}
	}
	for key, item := range current {
		if err := reconcileCurrent(state, key, item, at, policy); err != nil {
			return err
		}
	}
	for key, reason := range removed {
		closeReason, err := closeReason(reason)
		if err != nil {
			return err
		}
		if err := reconcileRemoved(state, key, closeReason); err != nil {
			return err
		}
	}
	state.Snapshots[poll.AccountLabel] = storage.Snapshot{FetchedAt: poll.FetchedAt, Meetings: append([]meeting.Meeting(nil), poll.Meetings...)}
	state.Health[poll.AccountLabel] = storage.Health{LastSuccess: poll.FetchedAt}
	return nil
}

func validateObservation(observation meeting.Observation) error {
	if observation.Key == "" {
		return &InvalidPollError{Field: "observations.key"}
	}
	if observation.Reason != "" {
		if observation.Exclusion != "" {
			return &InvalidPollError{Field: "observations.exclusion"}
		}
		switch observation.Reason {
		case meeting.RemovedCancelled, meeting.RemovedDeclined, meeting.RemovedURL, meeting.RemovedNonActionable:
			return nil
		default:
			return &InvalidPollError{Field: "observations.reason"}
		}
	}
	switch observation.Exclusion {
	case meeting.ExcludedAllDay, meeting.ExcludedMissingStart, meeting.ExcludedMalformedURL, meeting.ExcludedMissingURL, meeting.ExcludedUnsupportedURL:
		return nil
	default:
		return &InvalidPollError{Field: "observations.exclusion"}
	}
}

func knownMeeting(state *storage.State, previous storage.Snapshot, key string) bool {
	if _, exists := state.Occurrences[key]; exists {
		return true
	}
	for _, item := range previous.Meetings {
		if item.Key == key {
			return true
		}
	}
	return false
}

func reconcileCurrent(state *storage.State, key string, item meeting.Meeting, at time.Time, policy Policy) error {
	o, known := state.Occurrences[key]
	if !known {
		state.Occurrences[key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseScheduled}
		return nil
	}
	if o.Phase == storage.PhaseJoined {
		o.Meeting = item
		state.Occurrences[key] = o
		return nil
	}
	if !replacementRelevantChanged(o.Meeting, item) {
		o.Meeting = item
		state.Occurrences[key] = o
		return nil
	}
	switch o.Phase {
	case storage.PhaseNotifyPending:
		revision, err := storage.NextRevision(o.NotifyRevision)
		if err != nil {
			return err
		}
		o.NotifyRevision = revision
		if policy.due(item, at) {
			o.Meeting, o.NotBefore, o.Attempt = item, at, 0
		} else if o.NotificationID != 0 {
			beginClose(&o, storage.CloseRescheduled, storage.PhaseScheduled)
			o.Meeting = item
		} else {
			o.Meeting, o.Phase, o.NotBefore, o.Attempt = item, storage.PhaseScheduled, time.Time{}, 0
		}
	case storage.PhaseNotified, storage.PhaseActionableHistory, storage.PhaseJoinPending:
		if policy.due(item, at) {
			if err := prepareReplacement(&o, item, at); err != nil {
				return err
			}
		} else {
			beginClose(&o, storage.CloseRescheduled, storage.PhaseScheduled)
			o.Meeting = item
		}
	default:
		o.Meeting = item
	}
	state.Occurrences[key] = o
	return nil
}

func reconcileRemoved(state *storage.State, key string, reason storage.CloseReason) error {
	o, ok := state.Occurrences[key]
	if !ok || o.Phase == storage.PhaseJoined {
		return nil
	}
	switch o.Phase {
	case storage.PhaseScheduled:
		delete(state.Occurrences, key)
	case storage.PhaseNotifyPending:
		if o.NotificationID == 0 {
			delete(state.Occurrences, key)
			return nil
		}
		revision, err := storage.NextRevision(o.NotifyRevision)
		if err != nil {
			return err
		}
		o.NotifyRevision = revision
		beginClose(&o, reason, "")
		state.Occurrences[key] = o
	case storage.PhaseNotified, storage.PhaseActionableHistory, storage.PhaseJoinPending:
		beginClose(&o, reason, "")
		state.Occurrences[key] = o
	}
	return nil
}

func prepareReplacement(o *storage.OccurrenceState, item meeting.Meeting, at time.Time) error {
	revision, err := storage.NextRevision(o.NotifyRevision)
	if err != nil {
		return err
	}
	o.NotifyRevision = revision
	o.Meeting = item
	o.Phase = storage.PhaseNotifyPending
	o.NotifiedAt, o.ActionExpiresAt, o.NotBefore, o.Attempt = time.Time{}, time.Time{}, at, 0
	o.JoinRequestedAt, o.JoinedAt, o.CloseReason, o.ResumePhase = time.Time{}, time.Time{}, "", ""
	return nil
}

func replacementRelevantChanged(old, next meeting.Meeting) bool {
	return old.Summary != next.Summary || old.Start != next.Start || old.End != next.End || old.URL != next.URL || old.AccountLabel != next.AccountLabel
}

func beginClose(o *storage.OccurrenceState, reason storage.CloseReason, resume storage.Phase) {
	o.Phase, o.CloseReason, o.ResumePhase = storage.PhaseClosePending, reason, resume
	o.NotifiedAt, o.ActionExpiresAt, o.NotBefore, o.Attempt, o.JoinRequestedAt, o.JoinedAt = time.Time{}, time.Time{}, time.Time{}, 0, time.Time{}, time.Time{}
}

func closeReason(reason meeting.RemovedReason) (storage.CloseReason, error) {
	switch reason {
	case meeting.RemovedCancelled:
		return storage.CloseCancelled, nil
	case meeting.RemovedDeclined:
		return storage.CloseDeclined, nil
	case meeting.RemovedURL:
		return storage.CloseURLRemoved, nil
	case meeting.RemovedNonActionable:
		return storage.CloseNonActionable, nil
	default:
		return "", &InvalidPollError{Field: "observations.reason"}
	}
}
