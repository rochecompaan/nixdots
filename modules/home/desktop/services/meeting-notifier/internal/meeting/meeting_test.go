package meeting

import (
	"testing"
	"time"
)

func TestNormalizeAndDue(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	c := Candidate{
		AccountLabel:   "alpha",
		CalendarID:     "team",
		CalendarName:   "Team",
		EventID:        "event-1",
		Summary:        "Standup",
		Start:          now.Add(5 * time.Minute),
		End:            now.Add(35 * time.Minute),
		ConferenceURLs: []string{"https://meet.google.com/abc-defg-hij"},
	}
	got, ok, err := Normalize(c, []string{"meet.google.com", "zoom.us", "*.zoom.us"})
	if err != nil || !ok {
		t.Fatalf("got ok=%v err=%v", ok, err)
	}
	if !Due(got, now, 5*time.Minute) {
		t.Fatal("meeting should be due")
	}
	if got.Key == "" || got.AccountLabel != "alpha" {
		t.Fatalf("unexpected meeting: %#v", got)
	}
}

func TestDueRejectsMeetingsOutsideLeadWindow(t *testing.T) {
	now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	lead := 5 * time.Minute
	starts := []time.Time{
		now,
		now.Add(-time.Second),
		now.Add(lead + time.Second),
	}
	for _, start := range starts {
		if Due(Meeting{Start: start}, now, lead) {
			t.Fatalf("meeting at %s should not be due", start)
		}
	}
}

func TestOccurrenceKeyIsStableAcrossRescheduling(t *testing.T) {
	original := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
	base := Candidate{
		AccountLabel: "alpha", CalendarID: "team", EventID: "event-1",
		Summary: "Standup", Start: original,
		HangoutLink: "https://meet.google.com/abc-defg-hij",
	}
	moved := base
	moved.Start = original.Add(30 * time.Minute)
	first, ok, err := Normalize(base, []string{"meet.google.com"})
	if err != nil || !ok {
		t.Fatalf("normalize original: ok=%v err=%v", ok, err)
	}
	second, ok, err := Normalize(moved, []string{"meet.google.com"})
	if err != nil || !ok {
		t.Fatalf("normalize moved: ok=%v err=%v", ok, err)
	}
	if first.Key != second.Key {
		t.Fatalf("non-recurring key changed: %q != %q", first.Key, second.Key)
	}

	base.RecurringEventID = "series-1"
	base.OriginalStart = original
	moved = base
	moved.Start = original.Add(45 * time.Minute)
	first, _, err = Normalize(base, []string{"meet.google.com"})
	if err != nil {
		t.Fatal(err)
	}
	second, _, err = Normalize(moved, []string{"meet.google.com"})
	if err != nil {
		t.Fatal(err)
	}
	if first.Key != second.Key {
		t.Fatalf("recurring key changed: %q != %q", first.Key, second.Key)
	}
}

func TestOccurrenceKeyDiffersForRecurringInstances(t *testing.T) {
	first, err := OccurrenceKey(
		"alpha", "team", "instance-1", "series-1",
		time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	second, err := OccurrenceKey(
		"alpha", "team", "instance-1", "series-1",
		time.Date(2026, 7, 30, 9, 0, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("recurring instances with different original starts must have different keys")
	}
}

func TestNormalizeRejectsRecurringInstanceWithoutOriginalStart(t *testing.T) {
	candidate := Candidate{
		AccountLabel: "alpha", CalendarID: "team", EventID: "instance-1",
		RecurringEventID: "series-1", Start: time.Now().Add(time.Hour),
		HangoutLink: "https://meet.google.com/abc-defg-hij",
	}
	if _, _, err := Normalize(candidate, []string{"meet.google.com"}); err == nil {
		t.Fatal("expected missing original start to fail")
	}
}

func TestNormalizeSkipsNonMeetingEvents(t *testing.T) {
	base := Candidate{
		AccountLabel: "alpha", CalendarID: "team", EventID: "event-1",
		Start: time.Now().Add(time.Hour), HangoutLink: "https://meet.google.com/abc-defg-hij",
	}
	tests := []Candidate{
		func() Candidate { c := base; c.Cancelled = true; return c }(),
		func() Candidate { c := base; c.Declined = true; return c }(),
		func() Candidate { c := base; c.AllDay = true; return c }(),
		func() Candidate { c := base; c.HangoutLink = ""; return c }(),
	}
	for _, candidate := range tests {
		if _, ok, err := Normalize(candidate, []string{"meet.google.com"}); err != nil || ok {
			t.Fatalf("expected skip, got ok=%v err=%v candidate=%#v", ok, err, candidate)
		}
	}
}
