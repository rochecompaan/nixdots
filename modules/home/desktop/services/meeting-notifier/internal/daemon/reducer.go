package daemon

import (
	"fmt"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

const actionLifetime = 24 * time.Hour

type InvalidEventError struct {
	Field string
}

func (e *InvalidEventError) Error() string { return "invalid event " + e.Field }

type PollResult struct {
	AccountLabel            string
	AuthorizationGeneration string
	FetchedAt               time.Time
	Meetings                []meeting.Meeting
	Observations            []meeting.Observation
	Err                     error
}
type ActivityResult struct {
	CheckedAt time.Time
	Result    activity.Result
	Err       error
}
type LaunchResult struct {
	OccurrenceKey string
	AccountLabel  string
	JoinRevision  uint64
	Err           error
}
type EventKind int

const (
	TickEvent EventKind = iota + 1
	PollResultEvent
	ActivityResultEvent
	NotificationEvent
	LaunchResultEvent
)

type Event struct {
	Kind         EventKind
	At           time.Time
	Poll         *PollResult
	Activity     *ActivityResult
	Notification *notifications.Event
	Launch       *LaunchResult
}
type EffectKind int

const (
	ActivityEffect EffectKind = iota + 1
	NotifyEffect
	CloseEffect
	LaunchEffect
	AuthWarningEffect
)

type Effect struct {
	Kind          EffectKind
	OccurrenceKey string
	Notification  notifications.Command
	URL           string
	AccountLabel  string
	JoinRevision  uint64
}

func Reduce(state storage.State, event Event) (storage.State, []Effect, error) {
	return reduceWithPolicy(state, event, defaultPolicy())
}

func reduceWithPolicy(state storage.State, event Event, policy Policy) (storage.State, []Effect, error) {
	normalized := copyState(state)
	if _, err := normalized.NormalizeLegacy(); err != nil {
		return state, nil, err
	}
	index, err := normalized.NotificationIndex()
	if err != nil {
		return state, nil, err
	}
	return reduceWithIndex(normalized, index, event, policy.normalized())
}

func reduceWithIndex(state storage.State, index map[uint32]string, event Event, policy Policy) (storage.State, []Effect, error) {
	next := copyState(state)
	if _, err := next.NormalizeLegacy(); err != nil {
		return state, nil, err
	}
	if err := next.Validate(); err != nil {
		return state, nil, err
	}
	at := event.At
	if at.IsZero() {
		return state, nil, &InvalidEventError{Field: "at"}
	}
	var effects []Effect
	switch event.Kind {
	case TickEvent:
		prune(&next, at)
		if hasDue(next, at, policy) {
			effects = append(effects, Effect{Kind: ActivityEffect})
		}
	case ActivityResultEvent:
		if event.Activity == nil {
			return state, nil, fmt.Errorf("activity event is missing result")
		}
		if event.Activity.Result.Eligible || event.Activity.Result.Degraded || event.Activity.Err != nil {
			for key, occurrence := range next.Occurrences {
				if occurrence.Phase == storage.PhaseScheduled && policy.due(occurrence.Meeting, at) {
					revision, err := storage.NextRevision(occurrence.NotifyRevision)
					if err != nil {
						return state, nil, err
					}
					occurrence.NotifyRevision = revision
					occurrence.Phase, occurrence.NotBefore = storage.PhaseNotifyPending, at
					next.Occurrences[key] = occurrence
				}
			}
		}
	case NotificationEvent:
		if event.Notification == nil {
			return state, nil, fmt.Errorf("notification event is missing result")
		}
		effects = reduceNotification(&next, index, *event.Notification, at, policy)
	case LaunchResultEvent:
		if event.Launch == nil {
			return state, nil, fmt.Errorf("launch event is missing result")
		}
		occurrence, ok := next.Occurrences[event.Launch.OccurrenceKey]
		if !ok || occurrence.Phase != storage.PhaseJoinPending || occurrence.JoinRevision != event.Launch.JoinRevision {
			break
		}
		if event.Launch.Err != nil {
			occurrence.Phase, occurrence.JoinRequestedAt, occurrence.ResumePhase = occurrence.ResumePhase, time.Time{}, ""
		} else {
			occurrence.Phase, occurrence.JoinedAt = storage.PhaseJoined, at
			occurrence.NotificationID, occurrence.NotifiedAt, occurrence.ActionExpiresAt = 0, time.Time{}, time.Time{}
			occurrence.JoinRequestedAt, occurrence.ResumePhase = time.Time{}, ""
		}
		next.Occurrences[occurrence.Meeting.Key] = occurrence
	case PollResultEvent:
		if event.Poll == nil {
			return state, nil, fmt.Errorf("poll event is missing result")
		}
		if event.Poll.Err == nil {
			if err := reconcile(&next, *event.Poll, at, policy); err != nil {
				return state, nil, err
			}
		} else if warned, err := applyPollFailure(&next, *event.Poll, at); err != nil {
			return state, nil, err
		} else if warned {
			effects = append(effects, authWarningEffect(event.Poll.AccountLabel, next.PendingAuthWarnings[event.Poll.AccountLabel].Revision))
		}
	default:
		return state, nil, fmt.Errorf("unknown event kind %d", event.Kind)
	}
	expireNotifyPending(&next, at)
	if err := next.Validate(); err != nil {
		return state, nil, err
	}
	for _, effect := range pendingEffects(next, at, policy) {
		effects = append(effects, effect)
	}
	return next, effects, nil
}

func copyState(s storage.State) storage.State {
	n := storage.NewState()
	for k, v := range s.Snapshots {
		v.Meetings = append([]meeting.Meeting(nil), v.Meetings...)
		n.Snapshots[k] = v
	}
	for k, v := range s.Occurrences {
		n.Occurrences[k] = v
	}
	for k, v := range s.AuthWarnings {
		n.AuthWarnings[k] = v
	}
	for k, v := range s.AuthWarningRevisions {
		n.AuthWarningRevisions[k] = v
	}
	for k, v := range s.PendingAuthWarnings {
		n.PendingAuthWarnings[k] = v
	}
	for k, v := range s.Health {
		n.Health[k] = v
	}
	return n
}
