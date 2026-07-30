package googlecalendar

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"golang.org/x/oauth2"
	"google.golang.org/api/calendar/v3"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
)

func TestClientListCalendarsFollowsAllPages(t *testing.T) {
	var pageTokens []string
	client := newTestCalendarClient(t, func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/users/me/calendarList" {
			t.Errorf("path = %q", request.URL.Path)
			http.NotFound(response, request)
			return
		}
		pageToken := request.URL.Query().Get("pageToken")
		pageTokens = append(pageTokens, pageToken)
		response.Header().Set("Content-Type", "application/json")
		switch pageToken {
		case "":
			fmt.Fprint(response, `{"items":[{"id":"primary@example.test","summary":"Primary","primary":true}],"nextPageToken":"page-two"}`)
		case "page-two":
			fmt.Fprint(response, `{"items":[{"id":"team@example.test","summary":"Team"}]}`)
		default:
			t.Errorf("unexpected page token %q", pageToken)
		}
	})

	got, err := client.ListCalendars(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := []storage.CalendarRef{
		{ID: "primary@example.test", Summary: "Primary"},
		{ID: "team@example.test", Summary: "Team"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("calendars = %#v, want %#v", got, want)
	}
	if !reflect.DeepEqual(pageTokens, []string{"", "page-two"}) {
		t.Fatalf("page tokens = %#v", pageTokens)
	}
}

func TestClientListCandidatesFollowsPagesAndAdaptsRawEvents(t *testing.T) {
	start := time.Date(2030, 1, 1, 8, 0, 0, 0, time.UTC)
	end := time.Date(2030, 1, 2, 8, 0, 0, 0, time.UTC)
	var pageTokens []string
	client := newTestCalendarClient(t, func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/calendars/calendar-id/events" {
			t.Errorf("path = %q", request.URL.Path)
			http.NotFound(response, request)
			return
		}
		query := request.URL.Query()
		assertQueryValue(t, query, "singleEvents", "true")
		assertQueryValue(t, query, "showDeleted", "true")
		assertQueryValue(t, query, "orderBy", "startTime")
		assertQueryValue(t, query, "timeMin", start.Format(time.RFC3339))
		assertQueryValue(t, query, "timeMax", end.Format(time.RFC3339))
		assertQueryValue(t, query, "maxResults", "250")
		pageToken := query.Get("pageToken")
		pageTokens = append(pageTokens, pageToken)
		response.Header().Set("Content-Type", "application/json")
		switch pageToken {
		case "":
			fmt.Fprint(response, `{
				"items":[{
					"id":"moved-instance",
					"recurringEventId":"series-id",
					"originalStartTime":{"dateTime":"2030-01-01T09:00:00+01:00"},
					"summary":"Moved meeting",
					"start":{"dateTime":"2030-01-01T11:30:00+01:00"},
					"end":{"dateTime":"2030-01-01T12:00:00+01:00"},
					"attendees":[
						{"self":false,"responseStatus":"declined"},
						{"self":true,"responseStatus":"declined"}
					],
					"conferenceData":{"entryPoints":[
						{"entryPointType":"video","uri":"https://meet.google.com/abc-defg-hij"},
						{"entryPointType":"phone","uri":"tel:+15551234567"}
					]},
					"hangoutLink":"https://meet.google.com/fallback",
					"location":"https://unsupported.example.test/room",
					"description":"Join whenever; adapter must not filter this text"
				}],
				"nextPageToken":"page-two"
			}`)
		case "page-two":
			fmt.Fprint(response, `{
				"items":[
					{
						"id":"cancelled-event",
						"status":"cancelled",
						"summary":"Cancelled",
						"start":{"dateTime":"2030-01-01T13:00:00Z"},
						"end":{"dateTime":"2030-01-01T14:00:00Z"}
					},
					{
						"id":"all-day-event",
						"recurringEventId":"all-day-series",
						"originalStartTime":{"date":"2030-01-01"},
						"summary":"All day",
						"start":{"date":"2030-01-01"},
						"end":{"date":"2030-01-02"},
						"attendees":[{"self":false,"responseStatus":"declined"}]
					}
				]
			}`)
		default:
			t.Errorf("unexpected page token %q", pageToken)
		}
	})

	got, err := client.ListCandidates(context.Background(), "work", storage.CalendarRef{
		ID: "calendar-id", Summary: "Calendar name",
	}, start, end)
	if err != nil {
		t.Fatal(err)
	}
	want := []meeting.Candidate{
		{
			AccountLabel:     "work",
			CalendarID:       "calendar-id",
			CalendarName:     "Calendar name",
			EventID:          "moved-instance",
			RecurringEventID: "series-id",
			OriginalStart:    mustParseTime(t, "2030-01-01T09:00:00+01:00"),
			Summary:          "Moved meeting",
			Start:            mustParseTime(t, "2030-01-01T11:30:00+01:00"),
			End:              mustParseTime(t, "2030-01-01T12:00:00+01:00"),
			Declined:         true,
			ConferenceURLs:   []string{"https://meet.google.com/abc-defg-hij"},
			HangoutLink:      "https://meet.google.com/fallback",
			Location:         "https://unsupported.example.test/room",
			Description:      "Join whenever; adapter must not filter this text",
		},
		{
			AccountLabel: "work", CalendarID: "calendar-id", CalendarName: "Calendar name",
			EventID: "cancelled-event", Summary: "Cancelled",
			Start: mustParseTime(t, "2030-01-01T13:00:00Z"),
			End:   mustParseTime(t, "2030-01-01T14:00:00Z"), Cancelled: true,
		},
		{
			AccountLabel: "work", CalendarID: "calendar-id", CalendarName: "Calendar name",
			EventID: "all-day-event", RecurringEventID: "all-day-series",
			OriginalStart: time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC), Summary: "All day",
			Start: time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC),
			End:   time.Date(2030, 1, 2, 0, 0, 0, 0, time.UTC), AllDay: true,
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("candidates:\n got %#v\nwant %#v", got, want)
	}
	if !reflect.DeepEqual(pageTokens, []string{"", "page-two"}) {
		t.Fatalf("page tokens = %#v", pageTokens)
	}
}

func TestClientRejectsRecurringEventWithoutParsedOriginalStart(t *testing.T) {
	tests := map[string]string{
		"missing":   "",
		"malformed": `,"originalStartTime":{"dateTime":"not-a-time"}`,
	}
	for name, originalStart := range tests {
		t.Run(name, func(t *testing.T) {
			client := newTestCalendarClient(t, func(response http.ResponseWriter, _ *http.Request) {
				response.Header().Set("Content-Type", "application/json")
				fmt.Fprintf(response, `{"items":[{"id":"bad-instance","recurringEventId":"series"%s,"start":{"dateTime":"2030-01-01T11:00:00Z"},"end":{"dateTime":"2030-01-01T12:00:00Z"}}]}`, originalStart)
			})
			_, err := client.ListCandidates(context.Background(), "work", storage.CalendarRef{ID: "calendar-id"}, time.Time{}, time.Now())
			if err == nil || !strings.Contains(err.Error(), "event bad-instance original start") {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

func TestClientAdaptsTimeZoneQualifiedLocalEventTimes(t *testing.T) {
	location, err := time.LoadLocation("Africa/Johannesburg")
	if err != nil {
		t.Fatal(err)
	}
	event := &calendar.Event{
		Id:               "timezone-instance",
		RecurringEventId: "series-id",
		Start: &calendar.EventDateTime{
			DateTime: "2030-06-01T09:30:00",
			TimeZone: "Africa/Johannesburg",
		},
		End: &calendar.EventDateTime{
			DateTime: "2030-06-01T10:00:00",
			TimeZone: "Africa/Johannesburg",
		},
		OriginalStartTime: &calendar.EventDateTime{
			DateTime: "2030-06-01T09:00:00",
			TimeZone: "Africa/Johannesburg",
		},
	}

	candidate, err := adaptEvent("work", storage.CalendarRef{ID: "calendar-id"}, event)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := candidate.Start, time.Date(2030, 6, 1, 9, 30, 0, 0, location); !got.Equal(want) || got.Location().String() != location.String() {
		t.Fatalf("start = %s (%s), want %s (%s)", got, got.Location(), want, want.Location())
	}
	if got, want := candidate.End, time.Date(2030, 6, 1, 10, 0, 0, 0, location); !got.Equal(want) || got.Location().String() != location.String() {
		t.Fatalf("end = %s (%s), want %s (%s)", got, got.Location(), want, want.Location())
	}
	if got, want := candidate.OriginalStart, time.Date(2030, 6, 1, 9, 0, 0, 0, location); !got.Equal(want) || got.Location().String() != location.String() {
		t.Fatalf("original start = %s (%s), want %s (%s)", got, got.Location(), want, want.Location())
	}
}

func TestClientReportsContextForInvalidTimeZoneQualifiedLocalTimes(t *testing.T) {
	tests := []struct {
		name  string
		event *calendar.Event
		want  string
	}{
		{
			name: "invalid IANA zone on start",
			event: &calendar.Event{
				Id:    "invalid-zone",
				Start: &calendar.EventDateTime{DateTime: "2030-06-01T09:30:00", TimeZone: "Invalid/Zone"},
				End:   &calendar.EventDateTime{DateTime: "2030-06-01T10:00:00", TimeZone: "Africa/Johannesburg"},
			},
			want: `decode event invalid-zone start: load time zone "Invalid/Zone"`,
		},
		{
			name: "invalid local recurring original start",
			event: &calendar.Event{
				Id:               "invalid-original-start",
				RecurringEventId: "series-id",
				Start:            &calendar.EventDateTime{DateTime: "2030-06-01T09:30:00", TimeZone: "Africa/Johannesburg"},
				End:              &calendar.EventDateTime{DateTime: "2030-06-01T10:00:00", TimeZone: "Africa/Johannesburg"},
				OriginalStartTime: &calendar.EventDateTime{
					DateTime: "not-a-local-time",
					TimeZone: "Africa/Johannesburg",
				},
			},
			want: `decode event invalid-original-start original start: parse local time "not-a-local-time" in time zone "Africa/Johannesburg"`,
		},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			_, err := adaptEvent("work", storage.CalendarRef{ID: "calendar-id"}, testCase.event)
			if err == nil || !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("error = %v, want context %q", err, testCase.want)
			}
		})
	}
}

func TestClassifyErrorUsesStableTypedData(t *testing.T) {
	timeout := &net.DNSError{IsTimeout: true}
	tests := []struct {
		name string
		err  error
		want ErrorKind
	}{
		{name: "context cancellation", err: fmt.Errorf("wrapped: %w", context.Canceled), want: ErrorCancellation},
		{name: "invalid grant", err: fmt.Errorf("wrapped: %w", &oauth2.RetrieveError{ErrorCode: "invalid_grant"}), want: ErrorAuthentication},
		{name: "other OAuth retrieval", err: &oauth2.RetrieveError{ErrorCode: "temporarily_unavailable"}, want: ErrorPermanent},
		{name: "HTTP 401", err: &googleapi.Error{Code: http.StatusUnauthorized}, want: ErrorAuthentication},
		{name: "auth reason", err: apiError(http.StatusForbidden, "authError"), want: ErrorAuthentication},
		{name: "invalid credentials reason", err: apiError(http.StatusBadRequest, "invalidCredentials"), want: ErrorAuthentication},
		{name: "HTTP 429", err: &googleapi.Error{Code: http.StatusTooManyRequests}, want: ErrorRateLimit},
		{name: "403 rate limit", err: apiError(http.StatusForbidden, "rateLimitExceeded"), want: ErrorRateLimit},
		{name: "403 user rate limit", err: apiError(http.StatusForbidden, "userRateLimitExceeded"), want: ErrorRateLimit},
		{name: "403 quota", err: apiError(http.StatusForbidden, "quotaExceeded"), want: ErrorRateLimit},
		{name: "403 permanent", err: apiError(http.StatusForbidden, "forbidden"), want: ErrorPermanent},
		{name: "server error", err: &googleapi.Error{Code: http.StatusServiceUnavailable}, want: ErrorTransient},
		{name: "transport timeout", err: fmt.Errorf("request: %w", timeout), want: ErrorTransient},
		{name: "rendered invalid_grant is irrelevant", err: errors.New("invalid_grant"), want: ErrorPermanent},
		{name: "ordinary error", err: errors.New("broken"), want: ErrorPermanent},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			if got := ClassifyError(testCase.err); got != testCase.want {
				t.Fatalf("ClassifyError(%T) = %q, want %q", testCase.err, got, testCase.want)
			}
		})
	}
}

func newTestCalendarClient(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	service, err := calendar.NewService(t.Context(),
		option.WithEndpoint(server.URL+"/"),
		option.WithHTTPClient(server.Client()),
	)
	if err != nil {
		t.Fatal(err)
	}
	return NewClient(service)
}

func assertQueryValue(t *testing.T, query url.Values, key, want string) {
	t.Helper()
	if got := query.Get(key); got != want {
		t.Errorf("%s = %q, want %q", key, got, want)
	}
}

func mustParseTime(t *testing.T, raw string) time.Time {
	t.Helper()
	parsed, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func apiError(code int, reasons ...string) error {
	result := &googleapi.Error{Code: code}
	for _, reason := range reasons {
		result.Errors = append(result.Errors, googleapi.ErrorItem{Reason: reason})
	}
	return result
}
