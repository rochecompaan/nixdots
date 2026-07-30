package googlecalendar

import (
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestCalendarSourceRejectsMalformedBundleBeforeAnyLiveClient(t *testing.T) {
	source := CalendarSource{}
	_, err := source.SyncAccount(t.Context(), "alpha", storage.AuthorizationBundle{}, time.Time{}, time.Time{})
	if err == nil {
		t.Fatal("accepted malformed bundle")
	}
}
