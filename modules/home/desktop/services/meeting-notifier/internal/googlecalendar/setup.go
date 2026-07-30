package googlecalendar

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"golang.org/x/oauth2"
)

type Prompter interface {
	ConfirmIdentity(identity, label string) (bool, error)
	SelectCalendars(calendars []storage.CalendarRef) ([]storage.CalendarRef, error)
}

type ClientFactory func(context.Context, *oauth2.Config, *oauth2.Token) (*Client, error)

type Setup struct {
	Authorizer Authorizer
	NewClient  ClientFactory
	Prompter   Prompter
	Random     io.Reader
}

type PreparedSetup struct {
	Bundle storage.AuthorizationBundle
}

func (s Setup) Prepare(
	ctx context.Context,
	trusted config.Config,
	label string,
	credentialsJSON []byte,
) (PreparedSetup, error) {
	if _, ok := trusted.Accounts[label]; !ok {
		return PreparedSetup{}, fmt.Errorf("account label %q is absent from trusted static config", label)
	}
	if s.NewClient == nil {
		return PreparedSetup{}, errors.New("Google Calendar client factory is required")
	}
	if s.Prompter == nil {
		return PreparedSetup{}, errors.New("setup prompter is required")
	}
	if s.Random == nil {
		return PreparedSetup{}, errors.New("setup random source is required")
	}

	oauthConfig, token, err := s.Authorizer.Authorize(ctx, credentialsJSON)
	if err != nil {
		return PreparedSetup{}, err
	}
	if token == nil || token.RefreshToken == "" {
		return PreparedSetup{}, &SetupError{Kind: SetupMissingRefreshToken}
	}
	client, err := s.NewClient(ctx, oauthConfig, token)
	if err != nil {
		return PreparedSetup{}, fmt.Errorf("create Google Calendar client: %w", err)
	}
	if client == nil {
		return PreparedSetup{}, errors.New("Google Calendar client factory returned nil")
	}
	listed, err := client.listCalendars(ctx)
	if err != nil {
		return PreparedSetup{}, err
	}
	identity, err := primaryIdentity(listed)
	if err != nil {
		return PreparedSetup{}, err
	}
	confirmed, err := s.Prompter.ConfirmIdentity(identity, label)
	if err != nil {
		return PreparedSetup{}, fmt.Errorf("confirm authenticated identity: %w", err)
	}
	if !confirmed {
		return PreparedSetup{}, errors.New("authenticated identity was not confirmed")
	}

	calendars := calendarRefs(listed)
	selected, err := s.Prompter.SelectCalendars(append([]storage.CalendarRef(nil), calendars...))
	if err != nil {
		return PreparedSetup{}, fmt.Errorf("select calendars: %w", err)
	}
	selected, err = validateSelection(calendars, selected)
	if err != nil {
		return PreparedSetup{}, err
	}
	generationBytes := make([]byte, 32)
	if _, err := io.ReadFull(s.Random, generationBytes); err != nil {
		return PreparedSetup{}, fmt.Errorf("generate authorization bundle generation: %w", err)
	}

	bundle := storage.AuthorizationBundle{
		Version:     storage.AuthorizationVersion,
		Generation:  base64.RawURLEncoding.EncodeToString(generationBytes),
		OAuthClient: json.RawMessage(append([]byte(nil), credentialsJSON...)),
		Token:       *token,
		Identity:    identity,
		Calendars:   append([]storage.CalendarRef(nil), selected...),
	}
	if err := bundle.Validate(); err != nil {
		return PreparedSetup{}, fmt.Errorf("validate prepared authorization bundle: %w", err)
	}
	return PreparedSetup{Bundle: bundle}, nil
}

func primaryIdentity(calendars []listedCalendar) (string, error) {
	for _, item := range calendars {
		if item.primary {
			if strings.TrimSpace(item.ref.ID) == "" {
				return "", errors.New("primary calendar has no identity")
			}
			return item.ref.ID, nil
		}
	}
	return "", errors.New("Google Calendar list has no primary calendar identity")
}

func calendarRefs(listed []listedCalendar) []storage.CalendarRef {
	result := make([]storage.CalendarRef, 0, len(listed))
	for _, item := range listed {
		result = append(result, item.ref)
	}
	return result
}

func validateSelection(displayed, selected []storage.CalendarRef) ([]storage.CalendarRef, error) {
	if len(selected) == 0 {
		return nil, errors.New("at least one calendar must be selected")
	}
	available := make(map[string]storage.CalendarRef, len(displayed))
	for _, calendar := range displayed {
		available[calendar.ID] = calendar
	}
	seen := make(map[string]struct{}, len(selected))
	result := make([]storage.CalendarRef, 0, len(selected))
	for _, calendar := range selected {
		canonical, ok := available[calendar.ID]
		if !ok {
			return nil, fmt.Errorf("selected calendar %q was not displayed", calendar.ID)
		}
		if _, duplicate := seen[calendar.ID]; duplicate {
			return nil, fmt.Errorf("calendar %q was selected more than once", calendar.ID)
		}
		seen[calendar.ID] = struct{}{}
		result = append(result, canonical)
	}
	return result, nil
}
