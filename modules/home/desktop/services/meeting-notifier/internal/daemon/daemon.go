package daemon

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sync/atomic"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type Source interface {
	SyncAccount(context.Context, string, storage.AuthorizationBundle, time.Time, time.Time) (PollResult, error)
}
type StateStore interface {
	LoadState() (storage.State, error)
	SaveState(storage.State) error
}
type Activity interface {
	Current(context.Context) (activity.Result, error)
}
type Launcher interface {
	Open(context.Context, string, string) error
}
type Dispatch func(context.Context, Effect) error

var (
	ErrDeliveryAckFull = errors.New("notification acknowledgement channel is full")
	ErrStaleDelivery   = errors.New("notification delivery has no notify-pending occurrence")
)

type Loop struct {
	store         StateStore
	dispatch      Dispatch
	policy        Policy
	events        chan Event
	processed     atomic.Uint64
	published     atomic.Value
	before        func(Event)
	after         func(context.Context, Event, storage.State, bool) error
	start         func(context.Context, storage.State) error
	notifications chan notifications.Event
}

type ownerSnapshot struct {
	index map[uint32]string
}

func NewLoop(store StateStore, dispatch Dispatch) *Loop {
	return newLoopWithPolicy(store, dispatch, defaultPolicy())
}

func newLoopWithPolicy(store StateStore, dispatch Dispatch, policy Policy) *Loop {
	return &Loop{store: store, dispatch: dispatch, policy: policy.normalized(), events: make(chan Event)}
}
func (l *Loop) Send(ctx context.Context, event Event) error {
	event = copyEvent(event)
	select {
	case l.events <- event:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (l *Loop) Processed() uint64 { return l.processed.Load() }
func (l *Loop) NotificationIndex() map[uint32]string {
	published := l.published.Load()
	if published == nil {
		return map[uint32]string{}
	}
	return copyNotificationIndex(published.(ownerSnapshot).index)
}
func (l *Loop) publishIndex(index map[uint32]string) {
	l.published.Store(ownerSnapshot{index: copyNotificationIndex(index)})
}
func copyNotificationIndex(index map[uint32]string) map[uint32]string {
	copied := make(map[uint32]string, len(index))
	for id, key := range index {
		copied[id] = key
	}
	return copied
}
func (l *Loop) Run(ctx context.Context) error {
	loaded, err := l.store.LoadState()
	if err != nil {
		return fmt.Errorf("load daemon state: %w", err)
	}
	state := copyState(loaded)
	migrated, err := state.NormalizeLegacy()
	if err != nil {
		return err
	}
	beforeStartupCleanup := copyState(state)
	expireNotifyPending(&state, time.Now().UTC())
	if migrated || !reflect.DeepEqual(beforeStartupCleanup, state) {
		if err := l.store.SaveState(state); err != nil {
			return fmt.Errorf("prepare daemon state: %w", err)
		}
	}
	index, err := state.NotificationIndex()
	if err != nil {
		return err
	}
	l.publishIndex(index)
	if l.start != nil {
		if err := l.start(ctx, state); err != nil {
			return err
		}
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case notification := <-l.notifications:
			event := Event{Kind: NotificationEvent, At: time.Now().UTC(), Notification: &notification}
			if err := l.process(ctx, &state, &index, event); err != nil {
				return err
			}
		case event := <-l.events:
			if err := l.process(ctx, &state, &index, event); err != nil {
				return err
			}
		}
	}
}

func (l *Loop) process(ctx context.Context, state *storage.State, index *map[uint32]string, event Event) error {
	next, effects, reduceErr := reduceWithIndex(*state, *index, event, l.policy)
	if reduceErr != nil {
		return reduceErr
	}
	changed := !reflect.DeepEqual(*state, next)
	if isDelivery(event) && !changed {
		return l.deliveryFailure(event, ErrStaleDelivery)
	}
	if changed {
		if err := l.store.SaveState(next); err != nil {
			return l.deliveryFailure(event, err)
		}
		*state = next
		var err error
		*index, err = state.NotificationIndex()
		if err != nil {
			return err
		}
		l.publishIndex(*index)
	}
	if err := acknowledgeDelivery(event, true, nil); err != nil {
		return err
	}
	if l.before != nil {
		l.before(event)
	}
	l.processed.Add(1)
	for _, effect := range effects {
		if l.dispatch != nil {
			if err := l.dispatch(ctx, effect); err != nil {
				return err
			}
		}
	}
	if l.after != nil {
		return l.after(ctx, event, *state, changed)
	}
	return nil
}
func (l *Loop) deliveryFailure(event Event, saveErr error) error {
	if err := acknowledgeDelivery(event, false, saveErr); err != nil {
		return errors.Join(saveErr, err)
	}
	if event.Notification == nil || event.Notification.Completion == nil {
		return saveErr
	}
	select {
	case completion := <-event.Notification.Completion:
		return errors.Join(saveErr, completion)
	case <-time.After(notifications.CompensationCompletionTimeout):
		return errors.Join(saveErr, errors.New("notification compensation timed out"))
	}
}

func isDelivery(event Event) bool {
	return event.Kind == NotificationEvent && event.Notification != nil && event.Notification.Kind == notifications.NotificationDelivered && (event.Notification.OccurrenceKey != "" || event.Notification.AccountLabel != "")
}

func acknowledgeDelivery(event Event, persisted bool, result error) error {
	if event.Kind != NotificationEvent || event.Notification == nil || event.Notification.Kind != notifications.NotificationDelivered {
		return nil
	}
	if event.Notification.DeliveryAck == nil {
		return errors.New("delivery event is missing acknowledgement")
	}
	select {
	case event.Notification.DeliveryAck <- notifications.DeliveryAck{Persisted: persisted, Err: result}:
		return nil
	default:
		return ErrDeliveryAckFull
	}
}
func copyEvent(event Event) Event {
	if event.Poll != nil {
		p := *event.Poll
		p.Meetings = append([]meeting.Meeting(nil), p.Meetings...)
		p.Observations = append([]meeting.Observation(nil), p.Observations...)
		event.Poll = &p
	}
	if event.Activity != nil {
		a := *event.Activity
		event.Activity = &a
	}
	if event.Launch != nil {
		x := *event.Launch
		event.Launch = &x
	}
	if event.Notification != nil {
		n := *event.Notification
		event.Notification = &n
	}
	return event
}
