package daemon

import (
	"errors"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestAuthenticationFailurePersistsFailingBundleGeneration(t *testing.T) {
	poll := PollResult{AccountLabel: "alpha", AuthorizationGeneration: "generation-7", Err: &PollError{Kind: PollAuthentication, Err: errors.New("invalid_grant")}}
	next, _, err := Reduce(storage.NewState(), Event{Kind: PollResultEvent, At: time.Now().UTC(), Poll: &poll})
	if err != nil {
		t.Fatal(err)
	}
	if generation := next.Health["alpha"].AuthorizationGeneration; generation != "generation-7" {
		t.Fatalf("health does not retain failing generation: %#v", next.Health["alpha"])
	}
}
