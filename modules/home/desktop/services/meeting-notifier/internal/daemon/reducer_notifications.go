package daemon

import (
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func reduceNotification(state *storage.State, index map[uint32]string, event notifications.Event, at time.Time, policy Policy) []Effect {
	switch event.Kind {
	case notifications.NotificationCommandCompleted:
		completeClose(state, event)
	case notifications.NotificationDelivered:
		applyDelivery(state, event, at)
	case notifications.NotificationFailed:
		applyNotificationFailure(state, event, at)
	case notifications.SignalReceived:
		applySignal(state, index, event.Signal, at, policy)
	}
	return nil
}

func completeClose(state *storage.State, event notifications.Event) {
	o, ok := state.Occurrences[event.OccurrenceKey]
	if !ok || o.Phase != storage.PhaseClosePending || (event.NotificationID != 0 && o.NotificationID != event.NotificationID) {
		return
	}
	if o.ResumePhase == storage.PhaseScheduled || o.ResumePhase == storage.PhaseNotifyPending {
		o.Phase, o.NotificationID, o.CloseReason, o.ResumePhase = o.ResumePhase, 0, "", ""
		o.NotBefore, o.Attempt = time.Time{}, 0
		state.Occurrences[event.OccurrenceKey] = o
	} else {
		delete(state.Occurrences, event.OccurrenceKey)
	}
}

func applyDelivery(state *storage.State, event notifications.Event, at time.Time) {
	if event.AccountLabel != "" {
		warning, ok := state.PendingAuthWarnings[event.AccountLabel]
		if !ok || warning.Revision != event.Revision {
			return
		}
		delete(state.PendingAuthWarnings, event.AccountLabel)
		state.AuthWarnings[event.AccountLabel] = at
		return
	}
	o, ok := state.Occurrences[event.OccurrenceKey]
	if !ok || o.Phase != storage.PhaseNotifyPending || o.NotifyRevision != event.Revision {
		return
	}
	o.Phase, o.NotificationID, o.NotifiedAt, o.ActionExpiresAt, o.NotBefore, o.Attempt = storage.PhaseNotified, event.NotificationID, at, at.Add(actionLifetime), time.Time{}, 0
	state.Occurrences[o.Meeting.Key] = o
}

func applyNotificationFailure(state *storage.State, event notifications.Event, at time.Time) {
	if event.AccountLabel != "" {
		warning, ok := state.PendingAuthWarnings[event.AccountLabel]
		if !ok || warning.Revision != event.Revision {
			return
		}
		retry := NextRetry(at, warning.Attempt+1, nil)
		warning.Attempt, warning.NotBefore = retry.Attempt, retry.NextAttempt
		state.PendingAuthWarnings[event.AccountLabel] = warning
		return
	}
	o, ok := state.Occurrences[event.OccurrenceKey]
	if !ok {
		return
	}
	if o.Phase == storage.PhaseClosePending {
		if event.NotificationID == 0 || event.NotificationID != o.NotificationID {
			return
		}
		retry := closeRetry(at, o.Attempt+1, event.OccurrenceKey)
		o.Attempt, o.NotBefore = retry.Attempt, retry.NextAttempt
		state.Occurrences[o.Meeting.Key] = o
		return
	}
	if o.Phase != storage.PhaseNotifyPending || o.NotifyRevision != event.Revision {
		return
	}
	retry := NextRetry(at, o.Attempt+1, nil)
	o.Attempt, o.NotBefore = retry.Attempt, retry.NextAttempt
	state.Occurrences[o.Meeting.Key] = o
}

func applySignal(state *storage.State, index map[uint32]string, signal notifications.Signal, at time.Time, policy Policy) {
	key, ok := index[signal.ID]
	if !ok {
		return
	}
	o, ok := state.Occurrences[key]
	if !ok || o.NotificationID != signal.ID {
		return
	}
	if signal.Kind == notifications.ActionInvoked && signal.ActionKey == "join" && (o.Phase == storage.PhaseNotified || o.Phase == storage.PhaseActionableHistory) && at.Before(o.ActionExpiresAt) && policy.validActionURL(o.Meeting.URL) {
		revision, err := storage.NextRevision(o.JoinRevision)
		if err != nil {
			return
		}
		o.JoinRevision = revision
		o.Phase, o.JoinRequestedAt, o.ResumePhase = storage.PhaseJoinPending, at, o.Phase
		state.Occurrences[key] = o
		return
	}
	if signal.Kind != notifications.NotificationClosed || (o.Phase != storage.PhaseNotified && o.Phase != storage.PhaseClosePending) {
		return
	}
	if o.Phase == storage.PhaseClosePending {
		if o.ResumePhase != "" {
			o.Phase, o.NotificationID, o.NotifiedAt, o.ActionExpiresAt, o.CloseReason, o.ResumePhase = o.ResumePhase, 0, time.Time{}, time.Time{}, "", ""
			o.NotBefore, o.Attempt = time.Time{}, 0
			state.Occurrences[key] = o
		} else {
			delete(state.Occurrences, key)
		}
		return
	}
	o.Phase, o.CloseReason, o.ResumePhase = storage.PhaseActionableHistory, "", ""
	state.Occurrences[key] = o
}
