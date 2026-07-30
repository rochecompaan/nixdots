package daemon

import (
	"context"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func (r *Runtime) start(ctx context.Context, state storage.State) error {
	now := time.Now().UTC()
	r.activityGeneration++
	r.schedulePolls(ctx, now)
	return r.scheduleDurable(ctx, state, now)
}

func (r *Runtime) beforeEffects(event Event) {
	r.recordDiagnostic(event)
	switch event.Kind {
	case TickEvent:
		r.activityGeneration++
	case PollResultEvent:
		if event.Poll != nil {
			r.pollBusy[event.Poll.AccountLabel] = false
			r.recordPollResult(*event.Poll, event.At)
			if event.Poll.Err == nil {
				r.activityGeneration++
			}
		}
	case ActivityResultEvent:
		r.activityBusy = false
	case LaunchResultEvent:
		r.launcherBusy = false
	case NotificationEvent:
		if event.Notification != nil && (event.Notification.Kind == notifications.NotificationDelivered || event.Notification.Kind == notifications.NotificationFailed || event.Notification.Kind == notifications.NotificationCommandCompleted) {
			r.notifierBusy = false
		}
	}
}

func (r *Runtime) afterCommit(ctx context.Context, event Event, state storage.State, changed bool) error {
	if event.Kind == TickEvent {
		r.schedulePolls(ctx, event.At)
	} else if changed && event.Kind != ActivityResultEvent {
		r.activityGeneration++
	}
	return r.scheduleDurable(ctx, state, event.At)
}

func (r *Runtime) recordPollResult(result PollResult, now time.Time) {
	if result.Err == nil {
		r.retries.Succeeded(result.AccountLabel)
		return
	}
	r.retries.Failed(result.AccountLabel, now, r.config.Jitter)
}

func (r *Runtime) schedulePolls(ctx context.Context, now time.Time) {
	if r.config.Source == nil {
		return
	}
	for _, account := range r.config.Accounts {
		if r.pollBusy[account.Label] || r.retries[account.Label].NextAttempt.After(now) {
			continue
		}
		command := PollCommand{AccountLabel: account.Label, Bundle: account.Bundle, Start: now, End: now.Add(r.config.Horizon)}
		select {
		case r.PollCommands[account.Label] <- command:
			r.pollBusy[account.Label] = true
		case <-ctx.Done():
			return
		}
	}
}

func (r *Runtime) scheduleDurable(ctx context.Context, state storage.State, now time.Time) error {
	if hasDue(state, now, r.config.Policy) && !r.activityBusy && r.activityChecked != r.activityGeneration {
		if err := r.dispatch(ctx, Effect{Kind: ActivityEffect}); err != nil {
			return err
		}
		r.activityChecked = r.activityGeneration
	}
	keys := orderedOccurrenceKeys(state)
	if effect, ok := oldestNotificationEffect(state, keys, now, r.config.Policy); ok {
		if err := r.dispatch(ctx, effect); err != nil {
			return err
		}
	}
	if effect, ok := oldestLaunchEffect(state, keys); ok {
		if err := r.dispatch(ctx, effect); err != nil {
			return err
		}
	}
	if !r.notifierBusy {
		if effect, ok := oldestAuthWarningEffect(state, now); ok {
			if err := r.dispatch(ctx, effect); err != nil {
				return err
			}
		}
	}
	return nil
}
