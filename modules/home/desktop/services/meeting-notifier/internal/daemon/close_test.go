package daemon

import (
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestCloseCompletionDeletesClosedRemoval(t *testing.T) {
	now := time.Now()
	item := testMeeting(now.Add(time.Hour))
	state := storage.NewState()
	state.Occurrences[item.Key] = storage.OccurrenceState{Meeting: item, Phase: storage.PhaseClosePending, NotificationID: 1, CloseReason: storage.CloseDeleted}
	next, _, err := Reduce(state, Event{Kind: NotificationEvent, At: now, Notification: &notifications.Event{Kind: notifications.NotificationCommandCompleted, OccurrenceKey: item.Key}})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := next.Occurrences[item.Key]; ok {
		t.Fatal("close completion retained deleted occurrence")
	}
}
