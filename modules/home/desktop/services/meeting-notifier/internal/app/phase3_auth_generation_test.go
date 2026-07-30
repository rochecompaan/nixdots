package app

import (
	"encoding/json"
	"testing"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/availability"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/status"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestNewAuthorizationGenerationRecoversRunAfterRestart(t *testing.T) {
	bundle := validAuthorizationBundle()
	bundle.Generation = "generation-new"
	var health storage.Health
	if err := json.Unmarshal([]byte(`{"needsAuth":true,"authorizationGeneration":"generation-old"}`), &health); err != nil {
		t.Fatal(err)
	}
	state := storage.NewState()
	state.Health["alpha"] = health
	runnable, _ := classifyConfiguredAccounts(fakeAuthorizationLoader{"alpha": {bundle: bundle}}, []string{"alpha"}, state, nil)
	if len(runnable) != 1 {
		t.Fatalf("new authorization generation remained blocked: %#v", runnable)
	}
	if category := availability.Classify(nil, health, bundle.Generation); category != availability.Available {
		t.Fatalf("status still marks new generation unavailable: %q", category)
	}
	if got := status.Render(state, []status.Account{{Label: "alpha", Category: availability.Available}}); got == "" {
		t.Fatal("status did not render recovered account")
	}
}

func TestSameFailingAuthorizationGenerationRemainsBlocked(t *testing.T) {
	bundle := validAuthorizationBundle()
	bundle.Generation = "generation-same"
	var health storage.Health
	if err := json.Unmarshal([]byte(`{"needsAuth":true,"authorizationGeneration":"generation-same"}`), &health); err != nil {
		t.Fatal(err)
	}
	state := storage.NewState()
	state.Health["alpha"] = health
	runnable, _ := classifyConfiguredAccounts(fakeAuthorizationLoader{"alpha": {bundle: bundle}}, []string{"alpha"}, state, nil)
	if len(runnable) != 0 {
		t.Fatalf("same failing authorization generation became runnable: %#v", runnable)
	}
}
