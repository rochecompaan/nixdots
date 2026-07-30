package googlecalendar

import (
	"context"
	"fmt"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/daemon"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"golang.org/x/oauth2/google"
	calendarapi "google.golang.org/api/calendar/v3"
	"google.golang.org/api/option"
)

type CalendarSource struct {
	Store        *storage.Store
	AllowedHosts []string
}

func (s CalendarSource) SyncAccount(ctx context.Context, label string, bundle storage.AuthorizationBundle, start, end time.Time) (daemon.PollResult, error) {
	if err := bundle.Validate(); err != nil {
		return daemon.PollResult{}, fmt.Errorf("validate authorization for %s: %w", label, err)
	}
	if s.Store == nil {
		return daemon.PollResult{}, fmt.Errorf("calendar source store is required")
	}
	config, err := google.ConfigFromJSON(bundle.OAuthClient, calendarapi.CalendarReadonlyScope)
	if err != nil {
		return daemon.PollResult{}, fmt.Errorf("parse authorization for %s: %w", label, err)
	}
	source := NewPersistingTokenSource(config.TokenSource(ctx, &bundle.Token), s.Store, label, bundle)
	service, err := calendarapi.NewService(ctx, option.WithTokenSource(source))
	if err != nil {
		return daemon.PollResult{}, fmt.Errorf("create calendar client for %s: %w", label, err)
	}
	client := NewClient(service)
	result := daemon.PollResult{AccountLabel: label, FetchedAt: time.Now().UTC()}
	for _, calendar := range bundle.Calendars {
		poll, err := client.ListPoll(ctx, label, calendar, start, end, s.AllowedHosts)
		if err != nil {
			return daemon.PollResult{}, &daemon.PollError{Kind: daemon.PollErrorKind(ClassifyError(err)), Err: err}
		}
		result.Meetings = append(result.Meetings, poll.Meetings...)
		result.Observations = append(result.Observations, poll.Observations...)
	}
	return result, nil
}
