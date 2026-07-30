package app

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/availability"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"golang.org/x/oauth2"
)

const secretSentinels = "token-sentinel credentials-sentinel auth-code-sentinel description-sentinel calendar-id-sentinel https://acme.zoom.us/j/9135550199?source=sentinel"

func TestSetupReturnsStageSpecificRedactedPublicGuidance(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want Category
		text string
	}{
		{name: "pre rename", err: &storage.OperationError{Stage: storage.StageTempSync, Path: secretSentinels, Err: errors.New(secretSentinels)}, want: SetupWritePreserved, text: "Existing authorization was preserved; fix storage and safely rerun setup."},
		{name: "post rename", err: &storage.OperationError{Stage: storage.StageDirectorySync, Path: secretSentinels, Err: errors.New(secretSentinels)}, want: SetupWriteAmbiguous, text: "A complete authorization bundle may already be visible; run setup or status again, then restart meeting-notifier.service."},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			service := &restart{}
			err := (App{Setup: preparer{}, Store: &authStore{err: testCase.err}, Service: service}).SetupAccount(context.Background(), "alpha", []byte(secretSentinels))
			var public *PublicError
			if !errors.As(err, &public) || public.Category != testCase.want || PublicMessage(err) != testCase.text {
				t.Fatalf("error = %#v message=%q", err, PublicMessage(err))
			}
			assertNoSentinels(t, err.Error())
			if service.calls != 0 {
				t.Fatal("restarted after write failure")
			}
		})
	}
}

func TestSetupPreparationFailureIsRedacted(t *testing.T) {
	err := (App{Setup: preparer{err: errors.New(secretSentinels)}, Store: &authStore{}, Service: &restart{}}).SetupAccount(context.Background(), "alpha", nil)
	var public *PublicError
	if !errors.As(err, &public) || public.Category != SetupPreparation {
		t.Fatalf("error = %#v", err)
	}
	assertNoSentinels(t, err.Error())
	assertNoSentinels(t, PublicMessage(err))
}

func TestSetupRestartFailureSaysBundleIsDurableWithoutLeakingCause(t *testing.T) {
	err := (App{Setup: preparer{}, Store: &authStore{}, Service: &restart{err: errors.New(secretSentinels)}}).SetupAccount(context.Background(), "alpha", nil)
	var public *PublicError
	if !errors.As(err, &public) || public.Category != RestartRequired {
		t.Fatalf("error = %#v", err)
	}
	if got := PublicMessage(err); got != "Authorization is durable; manually restart meeting-notifier.service." {
		t.Fatalf("message = %q", got)
	}
	assertNoSentinels(t, err.Error())
}

func TestClassifyConfiguredAccountsContinuesAvailableAndReportsEveryUnavailable(t *testing.T) {
	bundle := validAuthorizationBundle()
	loader := fakeAuthorizationLoader{
		"available": {bundle: bundle},
		"missing":   {err: &storage.OperationError{Stage: storage.StageRead, Err: os.ErrNotExist}},
		"bad":       {err: &storage.CorruptAuthorizationError{Err: errors.New(secretSentinels)}},
		"stale":     {err: &storage.ErrStaleAuthorization{AccountLabel: "stale"}},
		"auth":      {bundle: bundle},
	}
	state := storage.NewState()
	state.Health["auth"] = storage.Health{NeedsAuth: true, AuthorizationGeneration: bundle.Generation}
	var reported []string
	accounts, statuses := classifyConfiguredAccounts(loader, []string{"available", "missing", "bad", "stale", "auth"}, state, func(label string, category availability.Category) {
		reported = append(reported, label+":"+string(category))
	})
	if len(accounts) != 1 || accounts[0].Label != "available" {
		t.Fatalf("runnable = %#v", accounts)
	}
	if len(statuses) != 5 || len(reported) != 4 {
		t.Fatalf("statuses=%#v reported=%#v", statuses, reported)
	}
	for _, line := range reported {
		assertNoSentinels(t, line)
	}
}

func TestNoUsableAccountsReturnsTypedRedactedError(t *testing.T) {
	_, _, err := runnableAccountSet(fakeAuthorizationLoader{"alpha": {err: errors.New(secretSentinels)}}, []string{"alpha"}, storage.NewState(), slog.Default())
	var public *PublicError
	if !errors.As(err, &public) || public.Category != NoUsableAccounts {
		t.Fatalf("error = %#v", err)
	}
	assertNoSentinels(t, err.Error())
}

func TestRunFailureIsRedactedAtPublicBoundary(t *testing.T) {
	err := publicRunError(errors.New(secretSentinels))
	var public *PublicError
	if !errors.As(err, &public) || public.Category != RuntimeFailure {
		t.Fatalf("error = %#v", err)
	}
	assertNoSentinels(t, err.Error())
	assertNoSentinels(t, PublicMessage(err))
}

type loadResult struct {
	bundle storage.AuthorizationBundle
	err    error
}
type fakeAuthorizationLoader map[string]loadResult

func (f fakeAuthorizationLoader) LoadAuthorization(label string) (storage.AuthorizationBundle, error) {
	result := f[label]
	return result.bundle, result.err
}

func validAuthorizationBundle() storage.AuthorizationBundle {
	return storage.AuthorizationBundle{Version: storage.AuthorizationVersion, Generation: "generation", OAuthClient: []byte(`{"installed":{"client_id":"client"}}`), Token: oauth2.Token{RefreshToken: "refresh"}, Identity: "identity", Calendars: []storage.CalendarRef{{ID: "calendar"}}}
}

func assertNoSentinels(t *testing.T, output string) {
	t.Helper()
	for _, sentinel := range strings.Fields(secretSentinels) {
		if strings.Contains(output, sentinel) {
			t.Fatalf("leaked %q in %q", sentinel, output)
		}
	}
}
