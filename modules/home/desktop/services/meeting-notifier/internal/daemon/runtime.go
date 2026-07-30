package daemon

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

var ErrCommandSlotFull = errors.New("daemon worker command slot is full")

type Account struct {
	Label  string
	Bundle storage.AuthorizationBundle
}
type RuntimeConfig struct {
	Store         StateStore
	Source        Source
	Accounts      []Account
	Activity      Activity
	Launcher      Launcher
	Notifications notifications.Transport
	PollInterval  time.Duration
	Horizon       time.Duration
	Jitter        func(time.Duration) time.Duration
	Policy        Policy
	Diagnostics   DiagnosticSink
}
type Runtime struct {
	loop                                     *Loop
	config                                   RuntimeConfig
	activityBusy, notifierBusy, launcherBusy bool
	pollBusy                                 map[string]bool
	retries                                  RetryAccounts
	pollDiagnostics                          map[string]PollErrorKind
	launcherDiagnostics                      map[string]string
	activityDiagnostic                       bool
	activityGeneration, activityChecked      uint64
	PollCommands                             map[string]chan PollCommand
	ActivityCommands                         chan struct{}
	NotificationCommands                     chan notifications.Command
	LaunchCommands                           chan Effect
}

func NewRuntime(config RuntimeConfig) *Runtime {
	config.Policy = config.Policy.normalized()
	r := &Runtime{
		config: config, pollBusy: make(map[string]bool), retries: make(RetryAccounts), pollDiagnostics: make(map[string]PollErrorKind), launcherDiagnostics: make(map[string]string),
		PollCommands: make(map[string]chan PollCommand), ActivityCommands: make(chan struct{}, 1),
		NotificationCommands: make(chan notifications.Command, 1), LaunchCommands: make(chan Effect, 1),
	}
	for _, account := range config.Accounts {
		r.PollCommands[account.Label] = make(chan PollCommand, 1)
	}
	r.loop = newLoopWithPolicy(config.Store, r.dispatch, config.Policy)
	r.loop.before = r.beforeEffects
	r.loop.after = r.afterCommit
	r.loop.start = r.start
	return r
}

func (r *Runtime) Send(ctx context.Context, event Event) error { return r.loop.Send(ctx, event) }

func (r *Runtime) Run(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var workers sync.WaitGroup
	start := func(fn func()) {
		workers.Add(1)
		go func() { defer workers.Done(); fn() }()
	}
	if r.config.Source != nil {
		for _, account := range r.config.Accounts {
			commands := r.PollCommands[account.Label]
			start(func() { RunPollWorker(runCtx, r.config.Source, commands, r.loop.events) })
		}
	}
	if r.config.Activity != nil {
		start(func() { RunActivityWorker(runCtx, r.config.Activity, r.ActivityCommands, r.loop.events) })
	}
	if r.config.Launcher != nil {
		start(func() { RunLauncherWorker(runCtx, r.config.Launcher, r.LaunchCommands, r.loop.events) })
	}
	if r.config.PollInterval > 0 {
		start(func() { r.ticks(runCtx) })
	}
	notificationDone := make(chan error, 1)
	if r.config.Notifications != nil {
		r.loop.notifications = make(chan notifications.Event)
		start(func() {
			notificationDone <- r.config.Notifications.Run(runCtx, r.NotificationCommands, r.loop.notifications)
		})
	}
	loopDone := make(chan error, 1)
	go func() { loopDone <- r.loop.Run(runCtx) }()

	var result error
	if r.config.Notifications == nil {
		result = <-loopDone
	} else {
		select {
		case result = <-loopDone:
		case notificationErr := <-notificationDone:
			cancel()
			result = errors.Join(notificationErr, <-loopDone)
		}
	}
	cancel()
	workers.Wait()
	var closeErr error
	if closer, ok := r.config.Activity.(interface{ Close() error }); ok {
		closeErr = closer.Close()
	}
	return errors.Join(result, closeErr)
}

func (r *Runtime) ticks(ctx context.Context) {
	ticker := time.NewTicker(r.config.PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			_ = r.Send(ctx, Event{Kind: TickEvent, At: time.Now().UTC()})
		case <-ctx.Done():
			return
		}
	}
}

func (r *Runtime) dispatch(ctx context.Context, effect Effect) error {
	switch effect.Kind {
	case ActivityEffect:
		if r.activityBusy {
			return nil
		}
		r.activityBusy = true
		r.activityChecked = r.activityGeneration
		select {
		case r.ActivityCommands <- struct{}{}:
			return nil
		default:
			return ErrCommandSlotFull
		}
	case NotifyEffect, CloseEffect:
		if r.notifierBusy {
			return nil
		}
		r.notifierBusy = true
		select {
		case r.NotificationCommands <- effect.Notification:
			return nil
		default:
			return ErrCommandSlotFull
		}
	case AuthWarningEffect:
		if r.notifierBusy {
			return nil
		}
		r.notifierBusy = true
		select {
		case r.NotificationCommands <- effect.Notification:
			return nil
		default:
			return ErrCommandSlotFull
		}
	case LaunchEffect:
		if r.launcherBusy {
			return nil
		}
		r.launcherBusy = true
		select {
		case r.LaunchCommands <- effect:
			return nil
		default:
			return ErrCommandSlotFull
		}
	default:
		return fmt.Errorf("unknown effect kind %d", effect.Kind)
	}
}
