package daemon

import (
	"sort"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func pendingEffects(state storage.State, at time.Time, policies ...Policy) []Effect {
	policy := defaultPolicy()
	if len(policies) != 0 {
		policy = policies[0].normalized()
	}
	keys := orderedOccurrenceKeys(state)
	effects := make([]Effect, 0, 2)
	if effect, ok := oldestNotificationEffect(state, keys, at, policy); ok {
		effects = append(effects, effect)
	}
	if effect, ok := oldestLaunchEffect(state, keys); ok {
		effects = append(effects, effect)
	}
	return effects
}

func orderedOccurrenceKeys(state storage.State) []string {
	keys := make([]string, 0, len(state.Occurrences))
	for key := range state.Occurrences {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		left, right := state.Occurrences[keys[i]].Meeting.Start, state.Occurrences[keys[j]].Meeting.Start
		if left.Equal(right) {
			return keys[i] < keys[j]
		}
		return left.Before(right)
	})
	return keys
}

func oldestNotificationEffect(state storage.State, keys []string, at time.Time, policy Policy) (Effect, bool) {
	for _, key := range keys {
		o := state.Occurrences[key]
		switch o.Phase {
		case storage.PhaseNotifyPending:
			if policy.due(o.Meeting, at) && !o.NotBefore.After(at) {
				return notifyEffect(key, o), true
			}
		case storage.PhaseClosePending:
			if !o.NotBefore.After(at) {
				return Effect{Kind: CloseEffect, OccurrenceKey: key, Notification: notifications.Command{Kind: notifications.CloseCommand, OccurrenceKey: key, NotificationID: o.NotificationID}}, true
			}
		}
	}
	return Effect{}, false
}

func oldestAuthWarningEffect(state storage.State, at time.Time) (Effect, bool) {
	labels := make([]string, 0, len(state.PendingAuthWarnings))
	for label := range state.PendingAuthWarnings {
		labels = append(labels, label)
	}
	sort.Slice(labels, func(i, j int) bool {
		left, right := state.PendingAuthWarnings[labels[i]], state.PendingAuthWarnings[labels[j]]
		if left.CreatedAt.Equal(right.CreatedAt) {
			return labels[i] < labels[j]
		}
		return left.CreatedAt.Before(right.CreatedAt)
	})
	for _, label := range labels {
		warning := state.PendingAuthWarnings[label]
		if !warning.NotBefore.After(at) {
			return authWarningEffect(label, warning.Revision), true
		}
	}
	return Effect{}, false
}

func oldestLaunchEffect(state storage.State, keys []string) (Effect, bool) {
	for _, key := range keys {
		o := state.Occurrences[key]
		if o.Phase == storage.PhaseJoinPending {
			return Effect{Kind: LaunchEffect, OccurrenceKey: key, URL: o.Meeting.URL, AccountLabel: o.Meeting.AccountLabel, JoinRevision: o.JoinRevision}, true
		}
	}
	return Effect{}, false
}

func authWarningEffect(label string, revision uint64) Effect {
	return Effect{Kind: AuthWarningEffect, AccountLabel: label, Notification: notifications.Command{
		Kind: notifications.NotifyCommand, AccountLabel: label, Revision: revision,
		Request: notifications.Request{
			Summary: "Meeting notifier authorization required",
			Body:    label,
		},
	}}
}

func notifyEffect(key string, o storage.OccurrenceState) Effect {
	return Effect{Kind: NotifyEffect, OccurrenceKey: key, Notification: notifications.Command{
		Kind: notifications.NotifyCommand, OccurrenceKey: key, Revision: o.NotifyRevision,
		Request: notifications.Request{
			ReplacesID: o.NotificationID,
			Summary:    o.Meeting.Summary,
			Body:       o.Meeting.AccountLabel + " · " + o.Meeting.Start.Local().Format("Mon Jan 2, 3:04 PM MST"),
			Actions:    []string{"join", "Join"},
		},
	}}
}

func hasDue(state storage.State, at time.Time, policy Policy) bool {
	for _, o := range state.Occurrences {
		if o.Phase == storage.PhaseScheduled && policy.due(o.Meeting, at) {
			return true
		}
	}
	return false
}
