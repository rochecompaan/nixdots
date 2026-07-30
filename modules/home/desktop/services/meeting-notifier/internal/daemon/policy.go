package daemon

import (
	"errors"
	"strings"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
)

const defaultLeadTime = 5 * time.Minute

var defaultAllowedHosts = []string{"meet.google.com", "zoom.us", "*.zoom.us"}

// Policy is an immutable copy of the timing and URL rules used by the owner.
type Policy struct {
	leadTime     time.Duration
	allowedHosts []string
}

func NewPolicy(leadTime time.Duration, allowedHosts []string) (Policy, error) {
	if leadTime <= 0 {
		return Policy{}, errors.New("lead time must be positive")
	}
	if len(allowedHosts) == 0 {
		return Policy{}, errors.New("allowed hosts must not be empty")
	}
	for _, host := range allowedHosts {
		trimmed := strings.TrimPrefix(host, "*.")
		if trimmed == "" || strings.ContainsAny(trimmed, "/:@ ") {
			return Policy{}, errors.New("allowed host is invalid")
		}
	}
	return Policy{leadTime: leadTime, allowedHosts: append([]string(nil), allowedHosts...)}, nil
}

func defaultPolicy() Policy {
	policy, _ := NewPolicy(defaultLeadTime, defaultAllowedHosts)
	return policy
}

func (p Policy) normalized() Policy {
	if p.leadTime <= 0 || len(p.allowedHosts) == 0 {
		return defaultPolicy()
	}
	return Policy{leadTime: p.leadTime, allowedHosts: append([]string(nil), p.allowedHosts...)}
}

func (p Policy) AllowedHosts() []string {
	return append([]string(nil), p.allowedHosts...)
}

func (p Policy) due(item meeting.Meeting, now time.Time) bool {
	return meeting.Due(item, now, p.leadTime)
}

func (p Policy) validActionURL(raw string) bool {
	_, err := meeting.ValidateURL(raw, p.allowedHosts)
	return err == nil
}
