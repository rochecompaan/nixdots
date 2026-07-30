package meeting

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/url"
	"strings"
	"time"
)

type Candidate struct {
	AccountLabel     string
	CalendarID       string
	CalendarName     string
	EventID          string
	RecurringEventID string
	OriginalStart    time.Time
	Summary          string
	Start            time.Time
	End              time.Time
	AllDay           bool
	Cancelled        bool
	Declined         bool
	ConferenceURLs   []string
	HangoutLink      string
	Location         string
	Description      string
}

type Meeting struct {
	Key              string    `json:"key"`
	AccountLabel     string    `json:"accountLabel"`
	CalendarID       string    `json:"calendarId"`
	CalendarName     string    `json:"calendarName"`
	EventID          string    `json:"eventId"`
	RecurringEventID string    `json:"recurringEventId,omitempty"`
	OriginalStart    time.Time `json:"originalStart,omitempty"`
	Summary          string    `json:"summary"`
	Start            time.Time `json:"start"`
	End              time.Time `json:"end"`
	URL              string    `json:"url"`
}

type ExclusionReason string

const (
	ExcludedAllDay         ExclusionReason = "all-day"
	ExcludedMissingStart   ExclusionReason = "missing-start"
	ExcludedMalformedURL   ExclusionReason = "malformed-url"
	ExcludedMissingURL     ExclusionReason = "missing-url"
	ExcludedUnsupportedURL ExclusionReason = "unsupported-url"
)

func OccurrenceKey(account, calendarID, eventID, recurringEventID string, originalStart time.Time) (string, error) {
	if account == "" || calendarID == "" || eventID == "" {
		return "", errors.New("account, calendar ID, and event ID are required")
	}

	stableEventID := eventID
	instance := ""
	if recurringEventID != "" {
		if originalStart.IsZero() {
			return "", errors.New("recurring instances require original start time")
		}
		stableEventID = recurringEventID
		instance = originalStart.UTC().Format(time.RFC3339Nano)
	}

	raw := strings.Join([]string{account, calendarID, stableEventID, instance}, "\x00")
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:]), nil
}

func Normalize(c Candidate, allowedHosts []string) (Meeting, bool, error) {
	item, exclusion, err := normalizeCandidate(c, allowedHosts)
	return item, exclusion == "", err
}

func normalizeCandidate(c Candidate, allowedHosts []string) (Meeting, ExclusionReason, error) {
	if c.Cancelled || c.Declined {
		return Meeting{}, ExclusionReason("non-actionable"), nil
	}
	if c.AllDay {
		return Meeting{}, ExcludedAllDay, nil
	}
	if c.Start.IsZero() {
		return Meeting{}, ExcludedMissingStart, nil
	}

	rawURL, err := selectURL(c, allowedHosts)
	if err != nil {
		return Meeting{}, classifyURLExclusion(c, allowedHosts), nil
	}

	key, err := OccurrenceKey(c.AccountLabel, c.CalendarID, c.EventID, c.RecurringEventID, c.OriginalStart)
	if err != nil {
		return Meeting{}, "", err
	}

	return Meeting{
		Key:              key,
		AccountLabel:     c.AccountLabel,
		CalendarID:       c.CalendarID,
		CalendarName:     c.CalendarName,
		EventID:          c.EventID,
		RecurringEventID: c.RecurringEventID,
		OriginalStart:    c.OriginalStart,
		Summary:          c.Summary,
		Start:            c.Start,
		End:              c.End,
		URL:              rawURL,
	}, "", nil
}

func classifyURLExclusion(c Candidate, allowedHosts []string) ExclusionReason {
	raw := append([]string(nil), c.ConferenceURLs...)
	raw = append(raw, c.HangoutLink)
	raw = append(raw, extractURLs(c.Location)...)
	raw = append(raw, extractURLs(c.Description)...)
	found := false
	for _, value := range raw {
		if strings.TrimSpace(value) == "" {
			continue
		}
		found = true
		parsed, err := url.Parse(value)
		if err == nil && strings.EqualFold(parsed.Scheme, "https") && parsed.Host != "" && parsed.User == nil {
			if !allowedHost(strings.TrimSuffix(strings.ToLower(parsed.Hostname()), "."), allowedHosts) {
				return ExcludedUnsupportedURL
			}
			continue
		}
		return ExcludedMalformedURL
	}
	if !found {
		return ExcludedMissingURL
	}
	return ExcludedMalformedURL
}

func Due(m Meeting, now time.Time, lead time.Duration) bool {
	delta := m.Start.Sub(now)
	return delta > 0 && delta <= lead
}
