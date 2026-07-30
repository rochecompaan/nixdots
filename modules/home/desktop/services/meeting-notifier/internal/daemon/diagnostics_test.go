package daemon

import (
	"bytes"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
)

type diagnosticRecorder struct {
	items []Diagnostic
}

func (r *diagnosticRecorder) Report(item Diagnostic) {
	r.items = append(r.items, item)
}

func TestRuntimeReportsStablePollCategoriesWithoutErrorDetails(t *testing.T) {
	const sentinel = "sentinel-access-token https://secret.example/private"
	recorder := &diagnosticRecorder{}
	runtime := NewRuntime(RuntimeConfig{Diagnostics: recorder})
	now := time.Now().UTC()
	cases := []struct {
		label string
		kind  PollErrorKind
	}{
		{label: "network", kind: PollTransient},
		{label: "auth", kind: PollAuthentication},
		{label: "rate", kind: PollRateLimit},
	}
	for _, testCase := range cases {
		runtime.beforeEffects(Event{Kind: PollResultEvent, At: now, Poll: &PollResult{AccountLabel: testCase.label, Err: &PollError{Kind: testCase.kind, Err: errors.New(sentinel)}}})
	}
	if len(recorder.items) != len(cases) {
		t.Fatalf("diagnostics = %#v", recorder.items)
	}
	for i, item := range recorder.items {
		if item.Component != "poll" || item.AccountLabel != cases[i].label || item.Category != string(cases[i].kind) {
			t.Fatalf("diagnostic[%d] = %#v", i, item)
		}
		if strings.Contains(strings.Join([]string{item.Component, item.AccountLabel, item.Category}, " "), sentinel) {
			t.Fatalf("diagnostic leaked sentinel: %#v", item)
		}
	}

	for _, testCase := range cases {
		runtime.beforeEffects(Event{Kind: PollResultEvent, At: now.Add(time.Minute), Poll: &PollResult{AccountLabel: testCase.label, Err: &PollError{Kind: testCase.kind, Err: errors.New(sentinel)}}})
	}
	if len(recorder.items) != len(cases) {
		t.Fatalf("repeated failures emitted hot-loop diagnostics: %#v", recorder.items)
	}
	runtime.beforeEffects(Event{Kind: PollResultEvent, At: now.Add(2 * time.Minute), Poll: &PollResult{AccountLabel: "network"}})
	runtime.beforeEffects(Event{Kind: PollResultEvent, At: now.Add(3 * time.Minute), Poll: &PollResult{AccountLabel: "network", Err: &PollError{Kind: PollTransient, Err: errors.New(sentinel)}}})
	if len(recorder.items) != len(cases)+1 {
		t.Fatalf("recovered category was not observable again: %#v", recorder.items)
	}
}

func TestRuntimeReportsActivityDegradationOnceUntilRecovery(t *testing.T) {
	recorder := &diagnosticRecorder{}
	runtime := NewRuntime(RuntimeConfig{Diagnostics: recorder})
	now := time.Now().UTC()
	degraded := Event{Kind: ActivityResultEvent, At: now, Activity: &ActivityResult{Result: activity.Result{Eligible: true, Degraded: true}, Err: errors.New("sentinel URL https://secret.example")}}
	runtime.beforeEffects(degraded)
	runtime.beforeEffects(degraded)
	if len(recorder.items) != 1 || recorder.items[0] != (Diagnostic{Component: "activity", Category: "degraded"}) {
		t.Fatalf("diagnostics = %#v", recorder.items)
	}
	runtime.beforeEffects(Event{Kind: ActivityResultEvent, At: now.Add(time.Minute), Activity: &ActivityResult{Result: activity.Result{Eligible: true}}})
	runtime.beforeEffects(degraded)
	if len(recorder.items) != 2 {
		t.Fatalf("recovered degradation was not observable again: %#v", recorder.items)
	}
}

func TestSlogDiagnosticSinkEmitsOnlyStableFields(t *testing.T) {
	var output bytes.Buffer
	sink := NewSlogDiagnosticSink(slog.New(slog.NewTextHandler(&output, nil)))
	sink.Report(Diagnostic{Component: "poll", AccountLabel: "alpha", Category: "transient"})
	got := output.String()
	for _, field := range []string{"component=poll", "account=alpha", "category=transient"} {
		if !strings.Contains(got, field) {
			t.Fatalf("log %q missing %q", got, field)
		}
	}
	if strings.Contains(got, "error=") || strings.Contains(got, "url=") {
		t.Fatalf("log contains forbidden detail fields: %q", got)
	}
}
