package launcher

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"
)

func (l *Launcher) snapshot(ctx context.Context) (map[uint64]struct{}, error) {
	windows, err := l.windows(ctx)
	if err != nil {
		return nil, err
	}
	return windowIDs(windows), nil
}

func (l *Launcher) windows(ctx context.Context) ([]niriWindow, error) {
	commandCtx, cancel := l.niriContext(ctx)
	defer cancel()
	data, err := l.processes.Output(commandCtx, l.niriBin, "msg", "--json", "windows")
	if err != nil {
		return nil, fmt.Errorf("query Niri windows: %w", err)
	}
	return decodeWindows(data)
}

func (l *Launcher) resolveWorkspace(ctx context.Context, workspace string) (workspaceTargetValue, error) {
	commandCtx, cancel := l.niriContext(ctx)
	defer cancel()
	data, err := l.processes.Output(commandCtx, l.niriBin, "msg", "--json", "workspaces")
	if err != nil {
		return workspaceTargetValue{}, fmt.Errorf("query Niri workspaces: %w", err)
	}
	workspaces, err := decodeWorkspaces(data)
	if err != nil {
		return workspaceTargetValue{}, err
	}
	return workspaceTarget(workspaces, workspace), nil
}

func (l *Launcher) observeWindows(ctx context.Context, match func([]niriWindow) (uint64, bool)) (uint64, bool, error) {
	observationCtx, cancel := context.WithTimeout(ctx, l.windowTimeout)
	defer cancel()
	id, found, err := l.waitForWindow(observationCtx, match)
	if err != nil {
		return 0, false, err
	}
	if err := ctx.Err(); err != nil {
		return 0, false, err
	}
	return id, found, nil
}

func (l *Launcher) waitForWindow(ctx context.Context, match func([]niriWindow) (uint64, bool)) (uint64, bool, error) {
	deadline := l.now().Add(l.windowTimeout)
	for l.now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				return 0, false, nil
			}
			return 0, false, err
		}
		windows, err := l.windows(ctx)
		if err != nil {
			return 0, false, err
		}
		if id, found := match(windows); found {
			return id, true, nil
		}
		if err := l.sleep(ctx, l.pollInterval); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				return 0, false, nil
			}
			return 0, false, err
		}
	}
	return 0, false, nil
}

func (l *Launcher) moveWindow(ctx context.Context, id uint64, target workspaceTargetValue) error {
	windowID := strconv.FormatUint(id, 10)
	var errs []error
	if target.Output != "" {
		errs = append(errs, l.action(ctx, "move-window-to-monitor", "--id", windowID, target.Output))
	}
	errs = append(errs, l.action(ctx, "move-window-to-workspace", "--window-id", windowID, "--focus", "false", target.Reference))
	return errors.Join(errs...)
}

func (l *Launcher) focusWindow(ctx context.Context, id uint64, target workspaceTargetValue) error {
	if err := l.focusTarget(ctx, target); err != nil {
		return err
	}
	return l.action(ctx, "focus-window", "--id", strconv.FormatUint(id, 10))
}

func (l *Launcher) focusTarget(ctx context.Context, target workspaceTargetValue) error {
	if target.Output != "" {
		if err := l.action(ctx, "focus-monitor", target.Output); err != nil {
			return err
		}
	}
	return l.action(ctx, "focus-workspace", target.Reference)
}

func (l *Launcher) action(ctx context.Context, action string, args ...string) error {
	commandArgs := append([]string{"msg", "action", action}, args...)
	commandCtx, cancel := l.niriContext(ctx)
	defer cancel()
	if err := l.processes.Run(commandCtx, l.niriBin, commandArgs...); err != nil {
		return fmt.Errorf("Niri action %s: %w", action, err)
	}
	return nil
}

func (l *Launcher) niriContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, l.commandTimeout)
}

func sleepContext(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
