package googlecalendar

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"golang.org/x/oauth2"
)

func TestSetupPreparesCompleteBundleAfterIdentityAndCalendarSelection(t *testing.T) {
	dataHome := t.TempDir()
	t.Setenv("XDG_DATA_HOME", dataHome)
	credentials := testCredentialsJSON()
	prompter := &recordingPrompter{
		confirmed: true,
		selected: []storage.CalendarRef{
			{ID: "team@example.test", Summary: "Team"},
		},
	}
	var factoryToken *oauth2.Token
	setup := Setup{
		Authorizer: setupAuthorizer(t),
		NewClient: func(_ context.Context, cfg *oauth2.Config, token *oauth2.Token) (*Client, error) {
			if cfg == nil {
				return nil, errors.New("nil OAuth config")
			}
			factoryToken = token
			return setupCalendarClient(t, []string{
				`{"items":[{"id":"person@example.test","summary":"Primary","primary":true}],"nextPageToken":"two"}`,
				`{"items":[{"id":"team@example.test","summary":"Team"}]}`,
			}), nil
		},
		Prompter: prompter,
		Random:   strings.NewReader(strings.Repeat("g", 32)),
	}

	prepared, err := setup.Prepare(context.Background(), trustedConfig("work"), "work", credentials)
	if err != nil {
		t.Fatal(err)
	}
	wantGeneration := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte("g"), 32))
	want := storage.AuthorizationBundle{
		Version:     storage.AuthorizationVersion,
		Generation:  wantGeneration,
		OAuthClient: append([]byte(nil), credentials...),
		Token:       *factoryToken,
		Identity:    "person@example.test",
		Calendars:   []storage.CalendarRef{{ID: "team@example.test", Summary: "Team"}},
	}
	if !reflect.DeepEqual(prepared.Bundle, want) {
		t.Fatalf("bundle:\n got %#v\nwant %#v", prepared.Bundle, want)
	}
	if err := prepared.Bundle.Validate(); err != nil {
		t.Fatalf("prepared bundle is invalid: %v", err)
	}
	if prompter.identity != "person@example.test" || prompter.label != "work" {
		t.Fatalf("confirmation = identity %q label %q", prompter.identity, prompter.label)
	}
	wantDisplayed := []storage.CalendarRef{
		{ID: "person@example.test", Summary: "Primary"},
		{ID: "team@example.test", Summary: "Team"},
	}
	if !reflect.DeepEqual(prompter.displayed, wantDisplayed) {
		t.Fatalf("displayed calendars = %#v", prompter.displayed)
	}

	credentials[0] = 'X'
	prompter.selected[0].ID = "mutated"
	if !reflect.DeepEqual([]byte(prepared.Bundle.OAuthClient), []byte(testCredentialsJSON())) {
		t.Fatal("prepared OAuth client aliases caller credentials")
	}
	if prepared.Bundle.Calendars[0].ID != "team@example.test" {
		t.Fatal("prepared calendars alias prompter selection")
	}
	entries, err := storageDirectoryEntries(dataHome)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("setup wrote runtime files: %v", entries)
	}
}

func TestSetupRejectsUntrustedLabelBeforeAuthorization(t *testing.T) {
	opened := false
	setup := Setup{
		Authorizer: Authorizer{Browser: BrowserFunc(func(string) error {
			opened = true
			return nil
		})},
	}
	prepared, err := setup.Prepare(context.Background(), trustedConfig("trusted"), "unknown", testCredentialsJSON())
	if err == nil || !strings.Contains(err.Error(), "trusted static config") {
		t.Fatalf("error = %v", err)
	}
	if !reflect.DeepEqual(prepared, PreparedSetup{}) {
		t.Fatalf("rejected setup returned %#v", prepared)
	}
	if opened {
		t.Fatal("authorization started for untrusted label")
	}
}

func TestSetupReturnsNothingWhenIdentityIsRejected(t *testing.T) {
	prompter := &recordingPrompter{confirmed: false}
	setup := validSetup(t, prompter)

	prepared, err := setup.Prepare(context.Background(), trustedConfig("work"), "work", testCredentialsJSON())
	if err == nil || !strings.Contains(err.Error(), "identity") {
		t.Fatalf("error = %v", err)
	}
	if !reflect.DeepEqual(prepared, PreparedSetup{}) {
		t.Fatalf("rejected identity returned %#v", prepared)
	}
	if prompter.selectCalled {
		t.Fatal("calendar selection ran after identity rejection")
	}
}

func TestSetupRejectsInvalidSelectedCalendars(t *testing.T) {
	tests := map[string][]storage.CalendarRef{
		"empty":       nil,
		"duplicate":   {{ID: "team@example.test"}, {ID: "team@example.test"}},
		"undisplayed": {{ID: "other@example.test"}},
	}
	for name, selected := range tests {
		t.Run(name, func(t *testing.T) {
			prompter := &recordingPrompter{confirmed: true, selected: selected}
			prepared, err := validSetup(t, prompter).Prepare(
				context.Background(), trustedConfig("work"), "work", testCredentialsJSON(),
			)
			if err == nil {
				t.Fatal("expected selection validation error")
			}
			if !reflect.DeepEqual(prepared, PreparedSetup{}) {
				t.Fatalf("invalid selection returned %#v", prepared)
			}
		})
	}
}

func TestSetupReturnsZeroPreparedSetupForClientAndEntropyFailures(t *testing.T) {
	factoryErr := errors.New("calendar factory unavailable")
	entropyErr := errors.New("entropy unavailable")
	tests := []struct {
		name    string
		mutate  func(*Setup)
		want    string
		wantErr error
	}{
		{
			name: "client factory error",
			mutate: func(setup *Setup) {
				setup.NewClient = func(context.Context, *oauth2.Config, *oauth2.Token) (*Client, error) {
					return nil, factoryErr
				}
			},
			want:    "create Google Calendar client",
			wantErr: factoryErr,
		},
		{
			name: "nil client",
			mutate: func(setup *Setup) {
				setup.NewClient = func(context.Context, *oauth2.Config, *oauth2.Token) (*Client, error) {
					return nil, nil
				}
			},
			want: "Google Calendar client factory returned nil",
		},
		{
			name: "short entropy",
			mutate: func(setup *Setup) {
				setup.Random = strings.NewReader(strings.Repeat("g", 31))
			},
			want: "generate authorization bundle generation: unexpected EOF",
		},
		{
			name: "erroring entropy",
			mutate: func(setup *Setup) {
				setup.Random = errorReader{err: entropyErr}
			},
			want:    "generate authorization bundle generation",
			wantErr: entropyErr,
		},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			setup := validSetup(t, &recordingPrompter{
				confirmed: true,
				selected:  []storage.CalendarRef{{ID: "team@example.test", Summary: "Team"}},
			})
			testCase.mutate(&setup)

			prepared, err := setup.Prepare(context.Background(), trustedConfig("work"), "work", testCredentialsJSON())
			if err == nil || !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("error = %v, want context %q", err, testCase.want)
			}
			if testCase.wantErr != nil && !errors.Is(err, testCase.wantErr) {
				t.Fatalf("error = %v, does not wrap %v", err, testCase.wantErr)
			}
			if !reflect.DeepEqual(prepared, PreparedSetup{}) {
				t.Fatalf("failure returned %#v", prepared)
			}
		})
	}
}

func TestSetupUsesCanonicalDisplayedCalendarReference(t *testing.T) {
	prompter := &recordingPrompter{
		confirmed: true,
		selected:  []storage.CalendarRef{{ID: "team@example.test", Summary: "forged summary"}},
	}
	prepared, err := validSetup(t, prompter).Prepare(
		context.Background(), trustedConfig("work"), "work", testCredentialsJSON(),
	)
	if err != nil {
		t.Fatal(err)
	}
	want := []storage.CalendarRef{{ID: "team@example.test", Summary: "Team"}}
	if !reflect.DeepEqual(prepared.Bundle.Calendars, want) {
		t.Fatalf("selected calendars = %#v, want canonical %#v", prepared.Bundle.Calendars, want)
	}
}

func TestSetupRejectsCalendarListWithoutPrimaryIdentity(t *testing.T) {
	setup := Setup{
		Authorizer: setupAuthorizer(t),
		NewClient: func(context.Context, *oauth2.Config, *oauth2.Token) (*Client, error) {
			return setupCalendarClient(t, []string{`{"items":[{"id":"team@example.test","summary":"Team"}]}`}), nil
		},
		Prompter: &recordingPrompter{confirmed: true},
		Random:   strings.NewReader(strings.Repeat("g", 32)),
	}

	prepared, err := setup.Prepare(context.Background(), trustedConfig("work"), "work", testCredentialsJSON())
	if err == nil || !strings.Contains(err.Error(), "primary calendar") {
		t.Fatalf("error = %v", err)
	}
	if !reflect.DeepEqual(prepared, PreparedSetup{}) {
		t.Fatalf("missing identity returned %#v", prepared)
	}
}

func TestTerminalPrompterRequiresExplicitYesAndPreservesBufferedSelection(t *testing.T) {
	var output bytes.Buffer
	prompter := NewTerminalPrompter(strings.NewReader("yes\n2, 1\n"), &output)
	confirmed, err := prompter.ConfirmIdentity("person@example.test", "work")
	if err != nil {
		t.Fatal(err)
	}
	if !confirmed {
		t.Fatal("explicit yes was rejected")
	}
	calendars := []storage.CalendarRef{
		{ID: "primary", Summary: "Primary"},
		{ID: "team", Summary: "Team"},
	}
	selected, err := prompter.SelectCalendars(calendars)
	if err != nil {
		t.Fatal(err)
	}
	want := []storage.CalendarRef{calendars[1], calendars[0]}
	if !reflect.DeepEqual(selected, want) {
		t.Fatalf("selected = %#v, want %#v", selected, want)
	}
	if got := output.String(); !strings.Contains(got, "1) Primary") || !strings.Contains(got, "2) Team") {
		t.Fatalf("calendar summaries not printed: %q", got)
	}

	for _, answer := range []string{"", "y", "true", "no"} {
		other := NewTerminalPrompter(strings.NewReader(answer+"\n"), &bytes.Buffer{})
		confirmed, err := other.ConfirmIdentity("person@example.test", "work")
		if err != nil {
			t.Fatalf("answer %q: %v", answer, err)
		}
		if confirmed {
			t.Fatalf("answer %q was accepted", answer)
		}
	}
}

func TestTerminalPrompterRejectsInvalidCalendarSelections(t *testing.T) {
	calendars := []storage.CalendarRef{{ID: "one", Summary: "One"}, {ID: "two", Summary: "Two"}}
	for _, input := range []string{"\n", "1,1\n", "0\n", "3\n", "one\n", "1,\n"} {
		t.Run(fmt.Sprintf("input_%q", input), func(t *testing.T) {
			prompter := NewTerminalPrompter(strings.NewReader(input), &bytes.Buffer{})
			selected, err := prompter.SelectCalendars(calendars)
			if err == nil {
				t.Fatalf("selection = %#v", selected)
			}
			if selected != nil {
				t.Fatalf("invalid input returned selection %#v", selected)
			}
		})
	}
}

type errorReader struct {
	err error
}

func (r errorReader) Read([]byte) (int, error) {
	return 0, r.err
}

type recordingPrompter struct {
	confirmed    bool
	selected     []storage.CalendarRef
	identity     string
	label        string
	displayed    []storage.CalendarRef
	selectCalled bool
}

func (p *recordingPrompter) ConfirmIdentity(identity, label string) (bool, error) {
	p.identity = identity
	p.label = label
	return p.confirmed, nil
}

func (p *recordingPrompter) SelectCalendars(calendars []storage.CalendarRef) ([]storage.CalendarRef, error) {
	p.selectCalled = true
	p.displayed = append([]storage.CalendarRef(nil), calendars...)
	return p.selected, nil
}

func trustedConfig(labels ...string) config.Config {
	accounts := make(map[string]config.Account, len(labels))
	for _, label := range labels {
		accounts[label] = config.Account{FirefoxProfile: "profile"}
	}
	return config.Config{Accounts: accounts}
}

func validSetup(t *testing.T, prompter Prompter) Setup {
	t.Helper()
	return Setup{
		Authorizer: setupAuthorizer(t),
		NewClient: func(context.Context, *oauth2.Config, *oauth2.Token) (*Client, error) {
			return setupCalendarClient(t, []string{`{"items":[
				{"id":"person@example.test","summary":"Primary","primary":true},
				{"id":"team@example.test","summary":"Team"}
			]}`}), nil
		},
		Prompter: prompter,
		Random:   strings.NewReader(strings.Repeat("g", 32)),
	}
}

func setupAuthorizer(t *testing.T) Authorizer {
	t.Helper()
	tokenServer := newTokenServer(t, true)
	t.Cleanup(tokenServer.Close)
	return testAuthorizer(tokenServer.URL, func(rawURL string) error {
		authURL, err := url.Parse(rawURL)
		if err != nil {
			return err
		}
		query := authURL.Query()
		return callLoopback(query.Get("redirect_uri"), url.Values{
			"state": {query.Get("state")},
			"code":  {"authorization-code"},
		}, nil)
	})
}

func setupCalendarClient(t *testing.T, pages []string) *Client {
	t.Helper()
	page := 0
	return newTestCalendarClient(t, func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/users/me/calendarList" {
			t.Errorf("path = %q", request.URL.Path)
			http.NotFound(response, request)
			return
		}
		if page >= len(pages) {
			t.Errorf("unexpected calendar page %d", page+1)
			http.Error(response, "unexpected page", http.StatusBadRequest)
			return
		}
		if page == 1 && request.URL.Query().Get("pageToken") != "two" {
			t.Errorf("pageToken = %q", request.URL.Query().Get("pageToken"))
		}
		response.Header().Set("Content-Type", "application/json")
		fmt.Fprint(response, pages[page])
		page++
	})
}

func storageDirectoryEntries(path string) ([]string, error) {
	entries, err := os.ReadDir(path)
	if err != nil {
		return nil, err
	}
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		result = append(result, entry.Name())
	}
	return result, nil
}
