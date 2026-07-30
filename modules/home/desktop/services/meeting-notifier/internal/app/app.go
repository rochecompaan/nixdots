package app

import (
	"context"
	"errors"
	"os/exec"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/googlecalendar"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type Preparer interface {
	Prepare(context.Context, string, []byte) (googlecalendar.PreparedSetup, error)
}
type AuthorizationStore interface {
	SaveAuthorization(string, storage.AuthorizationBundle) error
}
type ServiceManager interface{ Restart(context.Context) error }
type App struct {
	Setup   Preparer
	Store   AuthorizationStore
	Service ServiceManager
}

func (a App) SetupAccount(ctx context.Context, label string, credentials []byte) error {
	if a.Setup == nil || a.Store == nil || a.Service == nil {
		return publicError(SetupPreparation, "Authorization setup is unavailable; verify configuration and rerun setup.", nil)
	}
	prepared, err := a.Setup.Prepare(ctx, label, append([]byte(nil), credentials...))
	if err != nil {
		return publicError(SetupPreparation, "Authorization setup failed; correct the account or credentials and rerun setup.", err)
	}
	if err := a.Store.SaveAuthorization(label, prepared.Bundle); err != nil {
		return setupWriteError(err)
	}
	if err := a.Service.Restart(ctx); err != nil {
		return publicError(RestartRequired, "Authorization is durable; manually restart meeting-notifier.service.", err)
	}
	return nil
}

func setupWriteError(err error) error {
	var operation *storage.OperationError
	if !errors.As(err, &operation) {
		return publicError(SetupWriteAmbiguous, "Authorization storage failed; run setup or status again before restarting meeting-notifier.service.", err)
	}
	switch operation.Stage {
	case storage.StageDirectoryOpen, storage.StageDirectorySync, storage.StageDirectoryClose, storage.StageUnlock:
		return publicError(SetupWriteAmbiguous, "A complete authorization bundle may already be visible; run setup or status again, then restart meeting-notifier.service.", err)
	default:
		return publicError(SetupWritePreserved, "Existing authorization was preserved; fix storage and safely rerun setup.", err)
	}
}

type Systemctl struct{ Bin string }

func (s Systemctl) Restart(ctx context.Context) error {
	return exec.CommandContext(ctx, s.Bin, "--user", "restart", "meeting-notifier.service").Run()
}
