package app

import (
	"log/slog"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/availability"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/daemon"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/status"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type authorizationLoader interface {
	LoadAuthorization(string) (storage.AuthorizationBundle, error)
}

func classifyConfiguredAccounts(
	loader authorizationLoader,
	labels []string,
	state storage.State,
	report func(string, availability.Category),
) ([]daemon.Account, []status.Account) {
	runnable := make([]daemon.Account, 0, len(labels))
	accounts := make([]status.Account, 0, len(labels))
	for _, label := range labels {
		bundle, err := loader.LoadAuthorization(label)
		category := availability.Classify(err, state.Health[label], bundle.Generation)
		calendarSummaries := make([]string, 0, len(bundle.Calendars))
		if err == nil {
			for _, calendar := range bundle.Calendars {
				calendarSummaries = append(calendarSummaries, calendar.Summary)
			}
		}
		accounts = append(accounts, status.Account{Label: label, Category: category, CalendarSummaries: calendarSummaries})
		if category == availability.Available {
			runnable = append(runnable, daemon.Account{Label: label, Bundle: bundle})
		} else if report != nil {
			report(label, category)
		}
	}
	return runnable, accounts
}

func runnableAccountSet(loader authorizationLoader, labels []string, state storage.State, logger *slog.Logger) ([]daemon.Account, []status.Account, error) {
	runnable, accounts := classifyConfiguredAccounts(loader, labels, state, func(label string, category availability.Category) {
		logger.Warn("meeting notifier account unavailable", "account", label, "category", category)
	})
	if len(runnable) == 0 {
		return nil, accounts, publicError(NoUsableAccounts, "No configured accounts are usable; run meeting-notifier status and rerun setup for unavailable accounts.", nil)
	}
	return runnable, accounts, nil
}
