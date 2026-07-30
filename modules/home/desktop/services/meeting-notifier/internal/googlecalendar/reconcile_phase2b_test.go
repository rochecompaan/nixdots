package googlecalendar

import (
	"context"
	"fmt"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestListPollRequestsDeletedAndPreservesSparseCancellation(t *testing.T) {
	start := time.Date(2030, 1, 1, 8, 0, 0, 0, time.UTC)
	end := start.Add(24 * time.Hour)
	var pages []string
	client := newTestCalendarClient(t, func(response http.ResponseWriter, request *http.Request) {
		query := request.URL.Query()
		assertQueryValue(t, query, "singleEvents", "true")
		assertQueryValue(t, query, "showDeleted", "true")
		assertQueryValue(t, query, "orderBy", "startTime")
		assertQueryValue(t, query, "timeMin", start.Format(time.RFC3339))
		assertQueryValue(t, query, "timeMax", end.Format(time.RFC3339))
		assertQueryValue(t, query, "maxResults", "250")
		pages = append(pages, query.Get("pageToken"))
		response.Header().Set("Content-Type", "application/json")
		if query.Get("pageToken") == "" {
			fmt.Fprint(response, `{"items":[{"id":"cancelled-instance","status":"cancelled","recurringEventId":"series-id","originalStartTime":{"dateTime":"2030-01-01T09:00:00Z"}}],"nextPageToken":"two"}`)
			return
		}
		fmt.Fprint(response, `{"items":[{"id":"declined","start":{"dateTime":"2030-01-01T10:00:00Z"},"end":{"dateTime":"2030-01-01T10:30:00Z"},"attendees":[{"self":true,"responseStatus":"declined"}]}]}`)
	})

	poll, err := client.ListPoll(context.Background(), "alpha", storage.CalendarRef{ID: "calendar"}, start, end, []string{"meet.google.com"})
	if err != nil {
		t.Fatal(err)
	}
	cancelledKey, _ := meeting.OccurrenceKey("alpha", "calendar", "cancelled-instance", "series-id", time.Date(2030, 1, 1, 9, 0, 0, 0, time.UTC))
	declinedKey, _ := meeting.OccurrenceKey("alpha", "calendar", "declined", "", time.Time{})
	want := []meeting.Observation{{Key: cancelledKey, Reason: meeting.RemovedCancelled}, {Key: declinedKey, Reason: meeting.RemovedDeclined}}
	if !reflect.DeepEqual(poll.Observations, want) {
		t.Fatalf("observations = %#v, want %#v", poll.Observations, want)
	}
	if !reflect.DeepEqual(pages, []string{"", "two"}) {
		t.Fatalf("pages = %#v", pages)
	}
}

func TestListPollKeepsTypedNonActionableExclusionsSeparateFromURLRemoval(t *testing.T) {
	client := newTestCalendarClient(t, func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		fmt.Fprint(response, `{"items":[
			{"id":"all-day","start":{"date":"2030-01-01"},"end":{"date":"2030-01-02"}},
			{"id":"missing-start","end":{"dateTime":"2030-01-01T10:30:00Z"}},
			{"id":"malformed-url","start":{"dateTime":"2030-01-01T10:00:00Z"},"end":{"dateTime":"2030-01-01T10:30:00Z"},"hangoutLink":"://secret-invalid"},
			{"id":"lost-url","start":{"dateTime":"2030-01-01T11:00:00Z"},"end":{"dateTime":"2030-01-01T11:30:00Z"}},
			{"id":"unsupported-url","start":{"dateTime":"2030-01-01T12:00:00Z"},"end":{"dateTime":"2030-01-01T12:30:00Z"},"hangoutLink":"https://unsupported.example.test/room"}
		]}`)
	})
	poll, err := client.ListPoll(context.Background(), "alpha", storage.CalendarRef{ID: "calendar"}, time.Time{}, time.Now(), []string{"meet.google.com"})
	if err != nil {
		t.Fatal(err)
	}
	got := make(map[string]meeting.Observation)
	for _, observation := range poll.Observations {
		got[observation.Key] = observation
	}
	for eventID, exclusion := range map[string]meeting.ExclusionReason{
		"all-day": meeting.ExcludedAllDay, "missing-start": meeting.ExcludedMissingStart, "malformed-url": meeting.ExcludedMalformedURL,
	} {
		key, _ := meeting.OccurrenceKey("alpha", "calendar", eventID, "", time.Time{})
		if got[key].Exclusion != exclusion || got[key].Reason != "" {
			t.Fatalf("%s observation = %#v", eventID, got[key])
		}
	}
	for eventID, exclusion := range map[string]meeting.ExclusionReason{"lost-url": meeting.ExcludedMissingURL, "unsupported-url": meeting.ExcludedUnsupportedURL} {
		key, _ := meeting.OccurrenceKey("alpha", "calendar", eventID, "", time.Time{})
		if got[key].Reason != "" || got[key].Exclusion != exclusion {
			t.Fatalf("%s observation = %#v", eventID, got[key])
		}
	}
}
