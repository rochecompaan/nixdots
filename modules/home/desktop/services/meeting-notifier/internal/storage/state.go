package storage

import (
	"fmt"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
)

const StateVersion = 1

type Snapshot struct {
	FetchedAt time.Time         `json:"fetchedAt"`
	Meetings  []meeting.Meeting `json:"meetings"`
}

type Health struct {
	LastSuccess             time.Time `json:"lastSuccess"`
	LastError               string    `json:"lastError,omitempty"`
	NeedsAuth               bool      `json:"needsAuth"`
	AuthorizationGeneration string    `json:"authorizationGeneration,omitempty"`
}

type AuthWarningState struct {
	Revision  uint64    `json:"revision"`
	CreatedAt time.Time `json:"createdAt"`
	NotBefore time.Time `json:"notBefore"`
	Attempt   int       `json:"attempt,omitempty"`
}

type Phase string

const (
	PhaseScheduled         Phase = "scheduled"
	PhaseNotifyPending     Phase = "notify-pending"
	PhaseNotified          Phase = "notified"
	PhaseActionableHistory Phase = "actionable-history"
	PhaseJoinPending       Phase = "join-pending"
	PhaseJoined            Phase = "joined"
	PhaseClosePending      Phase = "close-pending"
)

type CloseReason string

const (
	CloseCancelled     CloseReason = "cancelled"
	CloseDeleted       CloseReason = "deleted"
	CloseDeclined      CloseReason = "declined"
	CloseURLRemoved    CloseReason = "url-removed"
	CloseRescheduled   CloseReason = "rescheduled"
	CloseNonActionable CloseReason = "non-actionable"
	CloseExpired       CloseReason = "expired"
)

type OccurrenceState struct {
	Meeting         meeting.Meeting `json:"meeting"`
	Phase           Phase           `json:"phase"`
	NotificationID  uint32          `json:"notificationId,omitempty"`
	NotifiedAt      time.Time       `json:"notifiedAt,omitempty"`
	ActionExpiresAt time.Time       `json:"actionExpiresAt,omitempty"`
	NotBefore       time.Time       `json:"notBefore,omitempty"`
	Attempt         int             `json:"attempt,omitempty"`
	JoinRequestedAt time.Time       `json:"joinRequestedAt,omitempty"`
	JoinedAt        time.Time       `json:"joinedAt,omitempty"`
	CloseReason     CloseReason     `json:"closeReason,omitempty"`
	ResumePhase     Phase           `json:"resumePhase,omitempty"`
	NotifyRevision  uint64          `json:"notifyRevision,omitempty"`
	JoinRevision    uint64          `json:"joinRevision,omitempty"`
}

type State struct {
	Version              int                         `json:"version"`
	Snapshots            map[string]Snapshot         `json:"snapshots"`
	Occurrences          map[string]OccurrenceState  `json:"occurrences"`
	AuthWarnings         map[string]time.Time        `json:"authWarnings"`
	AuthWarningRevisions map[string]uint64           `json:"authWarningRevisions"`
	PendingAuthWarnings  map[string]AuthWarningState `json:"pendingAuthWarnings"`
	Health               map[string]Health           `json:"health"`
}

type ValidationError struct {
	Field string
	Value string
}

func (e *ValidationError) Error() string {
	if e.Value == "" {
		return "invalid " + e.Field
	}
	return fmt.Sprintf("invalid %s %q", e.Field, e.Value)
}

type CorruptStateError struct {
	Path string
	Err  error
}

func (e *CorruptStateError) Error() string { return "corrupt state " + e.Path + ": " + e.Err.Error() }
func (e *CorruptStateError) Unwrap() error { return e.Err }

func NewState() State {
	return State{
		Version:              StateVersion,
		Snapshots:            make(map[string]Snapshot),
		Occurrences:          make(map[string]OccurrenceState),
		AuthWarnings:         make(map[string]time.Time),
		AuthWarningRevisions: make(map[string]uint64),
		PendingAuthWarnings:  make(map[string]AuthWarningState),
		Health:               make(map[string]Health),
	}
}

func (s State) Validate() error {
	if s.Version != StateVersion {
		return &ValidationError{Field: "version", Value: fmt.Sprint(s.Version)}
	}
	if s.Snapshots == nil || s.Occurrences == nil || s.AuthWarnings == nil || s.Health == nil {
		return &ValidationError{Field: "state maps"}
	}
	for label, warning := range s.PendingAuthWarnings {
		if label == "" || warning.Revision == 0 || warning.CreatedAt.IsZero() || warning.NotBefore.IsZero() || warning.Attempt < 0 || s.AuthWarningRevisions[label] != warning.Revision {
			return &ValidationError{Field: "pendingAuthWarnings", Value: label}
		}
	}
	notifications := make(map[uint32]string)
	for key, occurrence := range s.Occurrences {
		if key != occurrence.Meeting.Key {
			return &ValidationError{Field: "occurrences.key", Value: key}
		}
		if err := occurrence.Validate(); err != nil {
			return fmt.Errorf("occurrence %q: %w", key, err)
		}
		if occurrence.NotificationID == 0 {
			continue
		}
		if _, exists := notifications[occurrence.NotificationID]; exists {
			return &ValidationError{Field: "occurrences.notificationId", Value: fmt.Sprint(occurrence.NotificationID)}
		}
		notifications[occurrence.NotificationID] = key
	}
	return nil
}

func (s State) NotificationIndex() (map[uint32]string, error) {
	if err := s.Validate(); err != nil {
		return nil, err
	}
	index := make(map[uint32]string)
	for key, occurrence := range s.Occurrences {
		if occurrence.NotificationID != 0 {
			index[occurrence.NotificationID] = key
		}
	}
	return index, nil
}

func invalidField(field string) error { return &ValidationError{Field: field} }

func noTime(value time.Time) bool { return value.IsZero() }

func (o OccurrenceState) requireAction() error {
	if o.NotificationID == 0 {
		return invalidField("notificationId")
	}
	if o.NotifiedAt.IsZero() {
		return invalidField("notifiedAt")
	}
	if o.ActionExpiresAt.IsZero() {
		return invalidField("actionExpiresAt")
	}
	return nil
}

func (o OccurrenceState) noAction() bool {
	return o.NotificationID == 0 && noTime(o.NotifiedAt) && noTime(o.ActionExpiresAt)
}

func (o OccurrenceState) noRetry() bool {
	return noTime(o.NotBefore) && o.Attempt == 0
}

func (o OccurrenceState) noJoin() bool {
	return noTime(o.JoinRequestedAt) && noTime(o.JoinedAt)
}

func (o OccurrenceState) noClose() bool {
	return o.CloseReason == "" && o.ResumePhase == ""
}

func (o OccurrenceState) Validate() error {
	if o.Meeting.Key == "" || o.Meeting.AccountLabel == "" {
		return invalidField("meeting")
	}
	if o.Attempt < 0 {
		return invalidField("attempt")
	}
	switch o.Phase {
	case PhaseScheduled:
		if !o.noAction() || !o.noRetry() || !o.noJoin() || !o.noClose() {
			return invalidField("scheduled fields")
		}
	case PhaseNotifyPending:
		if !noTime(o.NotifiedAt) || !noTime(o.ActionExpiresAt) || !o.noJoin() || !o.noClose() {
			return invalidField("notify-pending fields")
		}
	case PhaseNotified, PhaseActionableHistory:
		if err := o.requireAction(); err != nil {
			return err
		}
		if !o.noRetry() || !o.noJoin() || !o.noClose() {
			return invalidField(string(o.Phase) + " fields")
		}
	case PhaseJoinPending:
		if err := o.requireAction(); err != nil {
			return err
		}
		if o.JoinRequestedAt.IsZero() || o.JoinRevision == 0 || (o.ResumePhase != PhaseNotified && o.ResumePhase != PhaseActionableHistory) {
			return invalidField("join-pending fields")
		}
		if !o.noRetry() || !noTime(o.JoinedAt) || o.CloseReason != "" {
			return invalidField("join-pending fields")
		}
	case PhaseJoined:
		if o.JoinedAt.IsZero() || o.JoinRevision == 0 || !o.noAction() || !o.noRetry() || !noTime(o.JoinRequestedAt) || !o.noClose() {
			return invalidField("joined fields")
		}
	case PhaseClosePending:
		if o.NotificationID == 0 || !validCloseReason(o.CloseReason) {
			return invalidField("close-pending fields")
		}
		if !noTime(o.NotifiedAt) || !noTime(o.ActionExpiresAt) || !o.noJoin() || (o.Attempt == 0) != o.NotBefore.IsZero() {
			return invalidField("close-pending fields")
		}
		if o.ResumePhase != "" && (o.CloseReason != CloseRescheduled || (o.ResumePhase != PhaseScheduled && o.ResumePhase != PhaseNotifyPending)) {
			return invalidField("resumePhase")
		}
	default:
		return &ValidationError{Field: "phase", Value: string(o.Phase)}
	}
	return nil
}

func validCloseReason(reason CloseReason) bool {
	switch reason {
	case CloseCancelled, CloseDeleted, CloseDeclined, CloseURLRemoved, CloseRescheduled, CloseNonActionable, CloseExpired:
		return true
	default:
		return false
	}
}
