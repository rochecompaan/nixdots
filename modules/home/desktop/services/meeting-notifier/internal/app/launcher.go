package app

import (
	"context"
	"fmt"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/daemon"
)

type profileLauncher struct {
	accounts map[string]config.Account
	launcher daemon.Launcher
}

func (p profileLauncher) Open(ctx context.Context, label, url string) error {
	account, ok := p.accounts[label]
	if !ok {
		return fmt.Errorf("unknown configured account %q", label)
	}
	return p.launcher.Open(ctx, account.FirefoxProfile, url)
}
