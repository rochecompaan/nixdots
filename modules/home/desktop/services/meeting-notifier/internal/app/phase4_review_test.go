package app

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/availability"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/daemon"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/status"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestLegacyAuthHealthPermitsOneProbeForLoadedGeneration(t *testing.T) {
	root := t.TempDir()
	layout := storage.Layout{
		DataDir:   filepath.Join(root, "data"),
		StateDir:  filepath.Join(root, "state"),
		StateFile: filepath.Join(root, "state", "state.json"),
	}
	store, err := storage.New(layout)
	if err != nil {
		t.Fatal(err)
	}
	legacy := `{"version":1,"snapshots":{},"occurrences":{},"authWarnings":{},"health":{"alpha":{"needsAuth":true}}}`
	if err := os.WriteFile(layout.StateFile, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := store.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	bundle := validAuthorizationBundle()
	bundle.Generation = "generation-new"

	runnable, statuses := classifyConfiguredAccounts(fakeAuthorizationLoader{"alpha": {bundle: bundle}}, []string{"alpha"}, state, nil)
	if len(runnable) != 1 || statuses[0].Category != availability.Available {
		t.Fatalf("legacy health blocked probe: runnable=%#v status=%#v", runnable, statuses)
	}
	if rendered := status.Render(state, statuses); !strings.Contains(rendered, "alpha: available") {
		t.Fatalf("status did not expose probe eligibility: %q", rendered)
	}

	failed, _, err := daemon.Reduce(state, daemon.Event{Kind: daemon.PollResultEvent, At: time.Now().UTC(), Poll: &daemon.PollResult{
		AccountLabel: "alpha", AuthorizationGeneration: bundle.Generation,
		Err: &daemon.PollError{Kind: daemon.PollAuthentication},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if health := failed.Health["alpha"]; !health.NeedsAuth || health.AuthorizationGeneration != bundle.Generation {
		t.Fatalf("failed probe did not record its generation: %#v", health)
	}
	runnable, statuses = classifyConfiguredAccounts(fakeAuthorizationLoader{"alpha": {bundle: bundle}}, []string{"alpha"}, failed, nil)
	if len(runnable) != 0 || statuses[0].Category != availability.AuthRequired {
		t.Fatalf("failed generation did not become blocked: runnable=%#v status=%#v", runnable, statuses)
	}

	succeeded, _, err := daemon.Reduce(state, daemon.Event{Kind: daemon.PollResultEvent, At: time.Now().UTC(), Poll: &daemon.PollResult{
		AccountLabel: "alpha", AuthorizationGeneration: bundle.Generation, FetchedAt: time.Now().UTC(),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if health := succeeded.Health["alpha"]; health.NeedsAuth || health.AuthorizationGeneration != "" {
		t.Fatalf("successful probe did not clear auth health: %#v", health)
	}
}

func TestJoinedCancellationAndCleanupFailureIsPublicRuntimeFailure(t *testing.T) {
	sentinel := "cleanup-token-sentinel https://acme.zoom.us/j/secret"
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	runtimeErr := daemon.NewRuntime(daemon.RuntimeConfig{
		Store:    phase4Store{state: storage.NewState()},
		Activity: phase4Activity{closeErr: errors.New(sentinel)},
	}).Run(ctx)
	if !errors.Is(runtimeErr, context.Canceled) || !strings.Contains(runtimeErr.Error(), sentinel) {
		t.Fatalf("runtime did not join cancellation and cleanup failure: %v", runtimeErr)
	}

	err := publicRunError(runtimeErr)
	var public *PublicError
	if !errors.As(err, &public) || public.Category != RuntimeFailure {
		t.Fatalf("error = %#v", err)
	}
	if IsCleanCancellation(err) {
		t.Fatal("joined cleanup failure classified as clean cancellation")
	}
	for _, leak := range strings.Fields(sentinel) {
		if strings.Contains(err.Error(), leak) || strings.Contains(PublicMessage(err), leak) {
			t.Fatalf("leaked %q", leak)
		}
	}
}

func TestCleanCancellationRemainsSilent(t *testing.T) {
	err := publicRunError(errors.Join(context.Canceled))
	if !IsCleanCancellation(err) {
		t.Fatalf("clean cancellation classified as failure: %v", err)
	}
}

type phase4Store struct {
	state storage.State
}

func (s phase4Store) LoadState() (storage.State, error) { return s.state, nil }
func (phase4Store) SaveState(storage.State) error       { return nil }

type phase4Activity struct {
	closeErr error
}

func (phase4Activity) Current(context.Context) (activity.Result, error) {
	return activity.Result{}, nil
}
func (a phase4Activity) Close() error { return a.closeErr }
