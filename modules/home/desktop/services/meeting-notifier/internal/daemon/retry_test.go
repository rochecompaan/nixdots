package daemon

import (
	"testing"
	"time"
)

func TestRetryScheduleCapsExponentialDelayAndAddsBoundedJitter(t *testing.T) {
	now := time.Date(2025, 1, 2, 3, 4, 5, 0, time.UTC)
	want := []time.Duration{time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 15 * time.Minute, 15 * time.Minute}
	for attempt, base := range want {
		got := NextRetry(now, attempt+1, func(limit time.Duration) time.Duration { return limit })
		if got.Attempt != attempt+1 {
			t.Fatalf("attempt %d: got attempt %d", attempt+1, got.Attempt)
		}
		if delay := got.NextAttempt.Sub(now); delay != base+base/4 {
			t.Fatalf("attempt %d: got delay %s, want %s", attempt+1, delay, base+base/4)
		}
	}
}

func TestRetryStateIsPerAccount(t *testing.T) {
	now := time.Now()
	retries := RetryAccounts{}
	retries.Failed("alpha", now, func(time.Duration) time.Duration { return 0 })
	retries.Failed("alpha", now, func(time.Duration) time.Duration { return 0 })
	retries.Failed("upfront", now, func(time.Duration) time.Duration { return 0 })
	if retries["alpha"].Attempt != 2 || retries["upfront"].Attempt != 1 {
		t.Fatalf("retry attempts not isolated: %#v", retries)
	}
	retries.Succeeded("alpha")
	if _, exists := retries["alpha"]; exists {
		t.Fatal("successful account retained retry")
	}
}
