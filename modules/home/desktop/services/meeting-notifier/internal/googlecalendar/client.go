package googlecalendar

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"google.golang.org/api/calendar/v3"
)

type Client struct {
	service *calendar.Service
}

func NewClient(service *calendar.Service) *Client {
	return &Client{service: service}
}

func (c *Client) ListCalendars(ctx context.Context) ([]storage.CalendarRef, error) {
	listed, err := c.listCalendars(ctx)
	if err != nil {
		return nil, err
	}
	result := make([]storage.CalendarRef, 0, len(listed))
	for _, item := range listed {
		result = append(result, item.ref)
	}
	return result, nil
}

type listedCalendar struct {
	ref     storage.CalendarRef
	primary bool
}

func (c *Client) listCalendars(ctx context.Context) ([]listedCalendar, error) {
	var result []listedCalendar
	for pageToken := ""; ; {
		response, err := c.service.CalendarList.List().PageToken(pageToken).Context(ctx).Do()
		if err != nil {
			return nil, fmt.Errorf("list Google calendars: %w", err)
		}
		for _, item := range response.Items {
			result = append(result, listedCalendar{
				ref:     storage.CalendarRef{ID: item.Id, Summary: item.Summary},
				primary: item.Primary,
			})
		}
		if response.NextPageToken == "" {
			return result, nil
		}
		pageToken = response.NextPageToken
	}
}

func (c *Client) ListCandidates(
	ctx context.Context,
	accountLabel string,
	calendarRef storage.CalendarRef,
	start time.Time,
	end time.Time,
) ([]meeting.Candidate, error) {
	var result []meeting.Candidate
	for pageToken := ""; ; {
		response, err := c.service.Events.List(calendarRef.ID).
			SingleEvents(true).
			ShowDeleted(true).
			OrderBy("startTime").
			TimeMin(start.Format(time.RFC3339)).
			TimeMax(end.Format(time.RFC3339)).
			MaxResults(250).
			PageToken(pageToken).
			Context(ctx).
			Do()
		if err != nil {
			return nil, fmt.Errorf("list Google events for calendar %q: %w", calendarRef.ID, err)
		}
		for _, event := range response.Items {
			candidate, err := adaptEvent(accountLabel, calendarRef, event)
			if err != nil {
				return nil, err
			}
			result = append(result, candidate)
		}
		if response.NextPageToken == "" {
			return result, nil
		}
		pageToken = response.NextPageToken
	}
}

func adaptEvent(accountLabel string, calendarRef storage.CalendarRef, event *calendar.Event) (meeting.Candidate, error) {
	start, allDay, err := parseEventTime(event.Start)
	if err != nil {
		return meeting.Candidate{}, fmt.Errorf("decode event %s start: %w", event.Id, err)
	}
	end, _, err := parseEventTime(event.End)
	if err != nil {
		return meeting.Candidate{}, fmt.Errorf("decode event %s end: %w", event.Id, err)
	}
	originalStart := time.Time{}
	if event.RecurringEventId != "" {
		originalStart, _, err = parseRequiredEventTime(event.OriginalStartTime)
		if err != nil {
			return meeting.Candidate{}, fmt.Errorf("decode event %s original start: %w", event.Id, err)
		}
	}
	return meeting.Candidate{
		AccountLabel:     accountLabel,
		CalendarID:       calendarRef.ID,
		CalendarName:     calendarRef.Summary,
		EventID:          event.Id,
		RecurringEventID: event.RecurringEventId,
		OriginalStart:    originalStart,
		Summary:          event.Summary,
		Start:            start,
		End:              end,
		AllDay:           allDay,
		Cancelled:        event.Status == "cancelled",
		Declined:         selfDeclined(event.Attendees),
		ConferenceURLs:   videoConferenceURLs(event.ConferenceData),
		HangoutLink:      event.HangoutLink,
		Location:         event.Location,
		Description:      event.Description,
	}, nil
}

func parseEventTime(value *calendar.EventDateTime) (time.Time, bool, error) {
	if value == nil || value.Date == "" && value.DateTime == "" {
		return time.Time{}, false, nil
	}
	return parseRequiredEventTime(value)
}

func parseRequiredEventTime(value *calendar.EventDateTime) (time.Time, bool, error) {
	if value == nil {
		return time.Time{}, false, errors.New("value is missing")
	}
	if value.Date != "" {
		parsed, err := time.Parse(time.DateOnly, value.Date)
		return parsed, true, err
	}
	if value.DateTime == "" {
		return time.Time{}, false, errors.New("date and dateTime are missing")
	}
	parsed, err := time.Parse(time.RFC3339, value.DateTime)
	if err == nil || value.TimeZone == "" || !offsetlessDateTime(value.DateTime) {
		return parsed, false, err
	}
	location, err := time.LoadLocation(value.TimeZone)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("load time zone %q: %w", value.TimeZone, err)
	}
	parsed, err = time.ParseInLocation("2006-01-02T15:04:05", value.DateTime, location)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("parse local time %q in time zone %q: %w", value.DateTime, value.TimeZone, err)
	}
	return parsed, false, nil
}

func offsetlessDateTime(value string) bool {
	if strings.HasSuffix(value, "Z") {
		return false
	}
	if len(value) < len("+00:00") {
		return true
	}
	offset := value[len(value)-len("+00:00"):]
	return !(offset[0] == '+' || offset[0] == '-') ||
		offset[3] != ':' ||
		offset[1] < '0' || offset[1] > '9' ||
		offset[2] < '0' || offset[2] > '9' ||
		offset[4] < '0' || offset[4] > '9' ||
		offset[5] < '0' || offset[5] > '9'
}

func selfDeclined(attendees []*calendar.EventAttendee) bool {
	for _, attendee := range attendees {
		if attendee.Self && attendee.ResponseStatus == "declined" {
			return true
		}
	}
	return false
}

func videoConferenceURLs(data *calendar.ConferenceData) []string {
	if data == nil {
		return nil
	}
	var result []string
	for _, entry := range data.EntryPoints {
		if entry.EntryPointType == "video" && entry.Uri != "" {
			result = append(result, entry.Uri)
		}
	}
	return result
}
