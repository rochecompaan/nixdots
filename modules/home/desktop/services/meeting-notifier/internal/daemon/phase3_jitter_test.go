package daemon

import (
	"errors"
	"testing"
	"time"
)

func TestRuntimeUsesInjectedBoundedPollJitter(t *testing.T) {
	runtime := NewRuntime(RuntimeConfig{Jitter: func(limit time.Duration) time.Duration { return limit }})
	now := time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC)
	runtime.recordPollResult(PollResult{AccountLabel: "alpha", Err: errors.New("failure")}, now)
	if got, want := runtime.retries["alpha"].NextAttempt, now.Add(75*time.Second); !got.Equal(want) {
		t.Fatalf("retry with injected jitter = %v, want %v", got, want)
	}
}
