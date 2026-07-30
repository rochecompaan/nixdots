package daemon

import (
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

const authWarningInterval = 24 * time.Hour

func applyPollFailure(state *storage.State, result PollResult, at time.Time) (bool, error) {
	kind := pollErrorKind(result.Err)
	health := state.Health[result.AccountLabel]
	health.LastError = string(kind)
	health.NeedsAuth = kind == PollAuthentication
	if health.NeedsAuth {
		health.AuthorizationGeneration = result.AuthorizationGeneration
	} else {
		health.AuthorizationGeneration = ""
	}
	state.Health[result.AccountLabel] = health
	if kind != PollAuthentication {
		return false, nil
	}
	if _, pending := state.PendingAuthWarnings[result.AccountLabel]; pending {
		return false, nil
	}
	if previous, ok := state.AuthWarnings[result.AccountLabel]; ok && previous.Add(authWarningInterval).After(at) {
		return false, nil
	}
	revision, err := storage.NextRevision(state.AuthWarningRevisions[result.AccountLabel])
	if err != nil {
		return false, err
	}
	state.AuthWarningRevisions[result.AccountLabel] = revision
	state.PendingAuthWarnings[result.AccountLabel] = storage.AuthWarningState{Revision: revision, CreatedAt: at, NotBefore: at}
	return true, nil
}
