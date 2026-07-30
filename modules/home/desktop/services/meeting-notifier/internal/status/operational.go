package status

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

var statusURL = regexp.MustCompile(`(?i)https?://\S+`)

func operationalFields(state storage.State, account Account, now time.Time, staleAfter time.Duration) string {
	var result strings.Builder
	if len(account.CalendarSummaries) != 0 {
		result.WriteString(" calendars=[")
		summaries := append([]string(nil), account.CalendarSummaries...)
		sort.Strings(summaries)
		for index, summary := range summaries {
			if index != 0 {
				result.WriteByte(',')
			}
			result.WriteString(strconv.Quote(redactURLs(summary)))
		}
		result.WriteByte(']')
	}
	snapshot, cached := state.Snapshots[account.Label]
	if !cached || snapshot.FetchedAt.IsZero() {
		result.WriteString(" cache=unavailable")
		return result.String()
	}
	age := now.Sub(snapshot.FetchedAt)
	if age < 0 {
		age = 0
	}
	result.WriteString(" cache-age=" + age.Round(time.Second).String())
	freshness := "fresh"
	if staleAfter <= 0 || age > staleAfter {
		freshness = "stale"
	}
	result.WriteString(" freshness=" + freshness)
	if next, ok := nextMeeting(snapshot.Meetings, now); ok {
		phase := storage.PhaseScheduled
		if occurrence, exists := state.Occurrences[next.Key]; exists {
			phase = occurrence.Phase
		}
		result.WriteString(" next-title=" + strconv.Quote(redactURLs(next.Summary)))
		result.WriteString(" next-start=" + next.Start.Format(time.RFC3339))
		result.WriteString(" next-phase=" + string(phase))
	}
	return result.String()
}

func nextMeeting(items []meeting.Meeting, now time.Time) (meeting.Meeting, bool) {
	var next meeting.Meeting
	found := false
	for _, item := range items {
		if !item.Start.After(now) {
			continue
		}
		if !found || item.Start.Before(next.Start) || (item.Start.Equal(next.Start) && item.Key < next.Key) {
			next, found = item, true
		}
	}
	return next, found
}

func redactURLs(value string) string {
	return statusURL.ReplaceAllString(value, "[redacted-url]")
}
