package googlecalendar

import (
	"context"
	"fmt"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type Poll struct {
	Meetings     []meeting.Meeting
	Observations []meeting.Observation
}

// ListPoll exposes selected meetings and typed removals without discarding the
// stable identity carried by canceled or declined Google events.
func (c *Client) ListPoll(ctx context.Context, account string, calendar storage.CalendarRef, start, end time.Time, allowedHosts []string) (Poll, error) {
	var result Poll
	for page := ""; ; {
		response, err := c.service.Events.List(calendar.ID).SingleEvents(true).ShowDeleted(true).OrderBy("startTime").TimeMin(start.Format(time.RFC3339)).TimeMax(end.Format(time.RFC3339)).MaxResults(250).PageToken(page).Context(ctx).Do()
		if err != nil {
			return Poll{}, fmt.Errorf("list Google events for calendar %q: %w", calendar.ID, err)
		}
		for _, raw := range response.Items {
			candidate, err := adaptEvent(account, calendar, raw)
			if err != nil {
				return Poll{}, err
			}
			item, observation, err := meeting.ClassifyCandidate(candidate, allowedHosts)
			if err != nil {
				return Poll{}, err
			}
			if item.Key != "" {
				result.Meetings = append(result.Meetings, item)
			}
			if observation.Key != "" {
				result.Observations = append(result.Observations, observation)
			}
		}
		if response.NextPageToken == "" {
			return result, nil
		}
		page = response.NextPageToken
	}
}
