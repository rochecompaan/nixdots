package daemon

import (
	"bytes"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/launcher"
)

func TestRuntimeCoalescesStableLauncherDiagnosticsAndRecovers(t *testing.T) {
	const sentinel = "https://secret.example/token"
	recorder := &diagnosticRecorder{}
	runtime := NewRuntime(RuntimeConfig{Diagnostics: recorder})
	now := time.Now().UTC()
	failure := func(err error) Event {
		return Event{Kind: LaunchResultEvent, At: now, Launch: &LaunchResult{OccurrenceKey: "key", AccountLabel: "alpha", JoinRevision: 1, Err: err}}
	}
	runtime.beforeEffects(failure(errors.Join(launcher.ErrWindowTimeout, errors.New(sentinel))))
	runtime.beforeEffects(failure(errors.Join(launcher.ErrWindowTimeout, errors.New(sentinel))))
	if len(recorder.items) != 1 || recorder.items[0] != (Diagnostic{Component: "launcher", AccountLabel: "alpha", Category: "window-timeout"}) {
		t.Fatalf("diagnostics = %#v", recorder.items)
	}
	runtime.beforeEffects(failure(nil))
	runtime.beforeEffects(failure(errors.Join(launcher.ErrCommandTimeout, errors.New(sentinel))))
	if len(recorder.items) != 2 || recorder.items[1] != (Diagnostic{Component: "launcher", AccountLabel: "alpha", Category: "command-timeout"}) {
		t.Fatalf("diagnostics after recovery = %#v", recorder.items)
	}
}

func TestRuntimeSlogLauncherDiagnosticRedactsURLAndUnderlyingError(t *testing.T) {
	const sentinel = "https://acme.zoom.us/j/123?pwd=secret process exploded"
	var output bytes.Buffer
	sink := NewSlogDiagnosticSink(slog.New(slog.NewTextHandler(&output, nil)))
	runtime := NewRuntime(RuntimeConfig{Diagnostics: sink})
	runtime.beforeEffects(Event{Kind: LaunchResultEvent, At: time.Now().UTC(), Launch: &LaunchResult{OccurrenceKey: "key", AccountLabel: "alpha", JoinRevision: 1, Err: errors.New(sentinel)}})
	got := output.String()
	for _, field := range []string{"component=launcher", "account=alpha", "category=launch"} {
		if !strings.Contains(got, field) {
			t.Fatalf("missing %q in %q", field, got)
		}
	}
	if strings.Contains(got, sentinel) || strings.Contains(got, "zoom.us") || strings.Contains(got, "exploded") {
		t.Fatalf("launcher diagnostic leaked error: %q", got)
	}
}
