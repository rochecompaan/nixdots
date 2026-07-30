package daemon

import (
	"context"
	"errors"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/launcher"
)

func (r *Runtime) recordDiagnostic(event Event) {
	if r.config.Diagnostics == nil {
		return
	}
	switch event.Kind {
	case PollResultEvent:
		if event.Poll == nil {
			return
		}
		if event.Poll.Err == nil {
			delete(r.pollDiagnostics, event.Poll.AccountLabel)
			return
		}
		kind := pollErrorKind(event.Poll.Err)
		if r.pollDiagnostics[event.Poll.AccountLabel] == kind {
			return
		}
		r.pollDiagnostics[event.Poll.AccountLabel] = kind
		r.config.Diagnostics.Report(Diagnostic{Component: "poll", AccountLabel: event.Poll.AccountLabel, Category: string(kind)})
	case ActivityResultEvent:
		if event.Activity == nil {
			return
		}
		degraded := event.Activity.Result.Degraded || event.Activity.Err != nil
		if !degraded {
			r.activityDiagnostic = false
			return
		}
		if r.activityDiagnostic {
			return
		}
		r.activityDiagnostic = true
		r.config.Diagnostics.Report(Diagnostic{Component: "activity", Category: "degraded"})
	case LaunchResultEvent:
		if event.Launch == nil {
			return
		}
		label := event.Launch.AccountLabel
		if event.Launch.Err == nil {
			delete(r.launcherDiagnostics, label)
			return
		}
		category := launcherDiagnosticCategory(event.Launch.Err)
		if r.launcherDiagnostics[label] == category {
			return
		}
		r.launcherDiagnostics[label] = category
		r.config.Diagnostics.Report(Diagnostic{Component: "launcher", AccountLabel: label, Category: category})
	}
}

func launcherDiagnosticCategory(err error) string {
	switch {
	case errors.Is(err, launcher.ErrWindowTimeout):
		return "window-timeout"
	case errors.Is(err, launcher.ErrCommandTimeout), errors.Is(err, context.DeadlineExceeded):
		return "command-timeout"
	default:
		return "launch"
	}
}
