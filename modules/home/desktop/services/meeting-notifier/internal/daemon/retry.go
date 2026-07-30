package daemon

import (
	"hash/fnv"
	"time"
)

type Retry struct {
	Attempt     int
	NextAttempt time.Time
}

type RetryAccounts map[string]Retry

func NextRetry(now time.Time, attempt int, jitter func(time.Duration) time.Duration) Retry {
	if attempt < 1 {
		attempt = 1
	}
	delay := time.Minute << min(attempt-1, 4)
	if delay > 15*time.Minute {
		delay = 15 * time.Minute
	}
	if jitter == nil {
		jitter = func(time.Duration) time.Duration { return 0 }
	}
	j := jitter(delay / 4)
	if j < 0 {
		j = 0
	}
	if j > delay/4 {
		j = delay / 4
	}
	return Retry{Attempt: attempt, NextAttempt: now.Add(delay + j)}
}

func (r RetryAccounts) Failed(label string, now time.Time, jitter func(time.Duration) time.Duration) Retry {
	next := NextRetry(now, r[label].Attempt+1, jitter)
	r[label] = next
	return next
}

func (r RetryAccounts) Succeeded(label string) { delete(r, label) }

func closeRetry(now time.Time, attempt int, key string) Retry {
	return NextRetry(now, attempt, func(limit time.Duration) time.Duration {
		hash := fnv.New64a()
		_, _ = hash.Write([]byte(key))
		return time.Duration(hash.Sum64() % uint64(limit+1))
	})
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
