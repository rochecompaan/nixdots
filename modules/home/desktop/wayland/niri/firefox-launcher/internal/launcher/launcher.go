package launcher

import (
	"context"
	"errors"
	"fmt"
	"time"
)

var ErrWindowTimeout = errors.New("timed out waiting for Firefox window")

const defaultCommandTimeout = 5 * time.Second

type ProcessRunner interface {
	Output(context.Context, string, ...string) ([]byte, error)
	Run(context.Context, string, ...string) error
	Start(string, []string, []string) error
}

type Launcher struct {
	firefoxBin     string
	niriBin        string
	processes      ProcessRunner
	now            func() time.Time
	sleep          func(context.Context, time.Duration) error
	pollInterval   time.Duration
	windowTimeout  time.Duration
	restoreSettle  time.Duration
	commandTimeout time.Duration
}

func New(firefoxBin, niriBin string, processes ProcessRunner) *Launcher {
	return &Launcher{
		firefoxBin:     firefoxBin,
		niriBin:        niriBin,
		processes:      processes,
		now:            time.Now,
		sleep:          sleepContext,
		pollInterval:   250 * time.Millisecond,
		windowTimeout:  15 * time.Second,
		restoreSettle:  2 * time.Second,
		commandTimeout: defaultCommandTimeout,
	}
}

func NewOS(firefoxBin, niriBin string) *Launcher {
	return New(firefoxBin, niriBin, osProcesses{})
}

func (l *Launcher) LaunchProfile(ctx context.Context, workspace, profile string) error {
	target, err := l.resolveWorkspace(ctx, workspace)
	if err != nil {
		return err
	}
	before, err := l.snapshot(ctx)
	if err != nil {
		return err
	}
	if err := l.startFirefox([]string{"--new-instance", "-P", profile}, profile); err != nil {
		return err
	}

	_, found, err := l.observeWindows(ctx, func(windows []niriWindow) (uint64, bool) {
		ids := newWindowIDs(windows, before)
		return 0, len(ids) > 0
	})
	if err != nil {
		return err
	}
	if !found {
		return nil
	}
	if err := l.sleep(ctx, l.restoreSettle); err != nil {
		return err
	}
	windows, err := l.windows(ctx)
	if err != nil {
		return err
	}
	for _, id := range newWindowIDs(windows, before) {
		_ = l.moveWindow(ctx, id, target)
	}
	return nil
}

func (l *Launcher) OpenURL(ctx context.Context, workspace, profile, rawURL string) error {
	target, err := l.resolveWorkspace(ctx, workspace)
	if err != nil {
		return err
	}
	before, err := l.snapshot(ctx)
	if err != nil {
		return err
	}
	if err := l.startFirefox([]string{"-P", profile, "--new-window", rawURL}, profile); err != nil {
		return err
	}

	id, found, err := l.observeWindows(ctx, func(windows []niriWindow) (uint64, bool) {
		return matchingNewWindow(windows, before, profileAppID(profile))
	})
	if err != nil {
		return err
	}
	if !found {
		return ErrWindowTimeout
	}
	if err := l.moveWindow(ctx, id, target); err != nil {
		return err
	}
	return l.focusWindow(ctx, id, target)
}

func (l *Launcher) FocusWorkspace(ctx context.Context, workspace string) error {
	target, err := l.resolveWorkspace(ctx, workspace)
	if err != nil {
		return err
	}
	return l.focusTarget(ctx, target)
}

func (l *Launcher) startFirefox(args []string, profile string) error {
	appID := profileAppID(profile)
	env := []string{
		"MOZ_APP_REMOTINGNAME=" + appID,
		"MOZ_APP_LAUNCHER=" + appID,
	}
	if err := l.processes.Start(l.firefoxBin, args, env); err != nil {
		return fmt.Errorf("start Firefox: %w", err)
	}
	return nil
}
