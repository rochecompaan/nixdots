package app

import (
	"context"
	"crypto/rand"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"sort"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/activity"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/daemon"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/googlecalendar"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/launcher"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/notifications"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/status"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"golang.org/x/oauth2"
	calendarapi "google.golang.org/api/calendar/v3"
	"google.golang.org/api/option"
)

func Run(ctx context.Context, args []string) (result error) {
	defer func() { result = publicRunError(result) }()
	if len(args) == 0 {
		return publicError(InvalidUsage, "Usage: meeting-notifier setup|run|status", nil)
	}
	layout, err := storage.DefaultLayout()
	if err != nil {
		return err
	}
	cfg, err := config.Load(layout.ConfigFile)
	if err != nil {
		return err
	}
	store, err := storage.New(layout)
	if err != nil {
		return err
	}
	switch args[0] {
	case "status":
		return statusCommand(store, cfg)
	case "run":
		return runDaemon(ctx, store, cfg)
	case "setup":
		return setupCommand(ctx, store, cfg, args[1:])
	default:
		return publicError(InvalidUsage, "Usage: meeting-notifier setup|run|status", nil)
	}
}

func setupCommand(ctx context.Context, store *storage.Store, cfg config.Config, args []string) error {
	flags := flag.NewFlagSet("setup", flag.ContinueOnError)
	credentials := flags.String("credentials", "", "OAuth credentials JSON")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *credentials == "" || flags.NArg() != 1 {
		return publicError(InvalidUsage, "Usage: meeting-notifier setup --credentials /path/to/credentials.json <account-label>", nil)
	}
	data, err := os.ReadFile(*credentials)
	if err != nil {
		return fmt.Errorf("read credentials: %w", err)
	}
	setup := googlecalendar.Setup{Authorizer: googlecalendar.Authorizer{Browser: googlecalendar.NewBrowser(cfg), Random: rand.Reader, Timeout: 2 * time.Minute}, NewClient: calendarClient, Prompter: googlecalendar.NewTerminalPrompter(os.Stdin, os.Stdout), Random: rand.Reader}
	return (App{Setup: setupAdapter{setup: setup, cfg: cfg}, Store: store, Service: Systemctl{Bin: cfg.SystemctlBin}}).SetupAccount(ctx, flags.Arg(0), data)
}

func runDaemon(ctx context.Context, store *storage.Store, cfg config.Config) error {
	policy, err := daemon.NewPolicy(cfg.LeadTime, cfg.AllowedHosts)
	if err != nil {
		return err
	}
	state, err := loadApplicationState(store)
	if err != nil {
		return err
	}
	accounts, _, err := runnableAccountSet(store, configuredLabels(cfg), state, slog.Default())
	if err != nil {
		return err
	}
	reader := activity.NewReader()
	runtime := daemon.NewRuntime(daemon.RuntimeConfig{
		Store: &preloadedStateStore{StateStore: store, state: state}, Source: googlecalendar.CalendarSource{Store: store, AllowedHosts: policy.AllowedHosts()}, Accounts: accounts,
		Activity: reader, Launcher: profileLauncher{accounts: cfg.Accounts, launcher: launcher.NewOSClient(cfg)}, Notifications: notifications.NewClient(slog.Default()), PollInterval: cfg.PollInterval, Horizon: cfg.Horizon, Jitter: daemon.RandomJitter(rand.Reader),
		Policy: policy, Diagnostics: daemon.NewSlogDiagnosticSink(slog.Default()),
	})
	return runtime.Run(ctx)
}

func statusCommand(store *storage.Store, cfg config.Config) error {
	return statusCommandAt(store, cfg, os.Stdout, time.Now())
}

func statusCommandAt(store *storage.Store, cfg config.Config, output io.Writer, now time.Time) error {
	state, err := loadApplicationState(store)
	if err != nil {
		return err
	}
	accounts := make([]status.Account, 0, len(cfg.Accounts))
	_, accounts = classifyConfiguredAccounts(store, configuredLabels(cfg), state, nil)
	staleAfter := 2 * cfg.PollInterval
	if staleAfter <= 0 {
		staleAfter = 2 * time.Minute
	}
	if _, err := fmt.Fprint(output, status.RenderAt(state, accounts, now, staleAfter)); err != nil {
		return err
	}
	if status.Unavailable(accounts) {
		return publicError(AccountsUnavailable, "One or more accounts are unavailable; rerun setup for the categories shown by status.", nil)
	}
	return nil
}

type setupAdapter struct {
	setup googlecalendar.Setup
	cfg   config.Config
}

func (s setupAdapter) Prepare(ctx context.Context, label string, credentials []byte) (googlecalendar.PreparedSetup, error) {
	return s.setup.Prepare(ctx, s.cfg, label, credentials)
}
func calendarClient(ctx context.Context, oauthConfig *oauth2.Config, token *oauth2.Token) (*googlecalendar.Client, error) {
	service, err := calendarapi.NewService(ctx, option.WithTokenSource(oauthConfig.TokenSource(ctx, token)))
	if err != nil {
		return nil, err
	}
	return googlecalendar.NewClient(service), nil
}
func configuredLabels(cfg config.Config) []string {
	labels := make([]string, 0, len(cfg.Accounts))
	for label := range cfg.Accounts {
		labels = append(labels, label)
	}
	sort.Strings(labels)
	return labels
}

type preloadedStateStore struct {
	daemon.StateStore
	state storage.State
	used  bool
}

func (s *preloadedStateStore) LoadState() (storage.State, error) {
	if !s.used {
		s.used = true
		return s.state, nil
	}
	return s.StateStore.LoadState()
}
