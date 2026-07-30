package status

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/availability"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type Account struct {
	Label             string
	Category          availability.Category
	CalendarSummaries []string
}

func Render(state storage.State, accounts []Account) string {
	return RenderAt(state, accounts, time.Now(), 2*time.Minute)
}

func RenderAt(state storage.State, accounts []Account, now time.Time, staleAfter time.Duration) string {
	items := append([]Account(nil), accounts...)
	sort.Slice(items, func(i, j int) bool { return items[i].Label < items[j].Label })
	var lines []string
	for _, account := range items {
		category := categoryOf(account)
		health := state.Health[account.Label]
		line := fmt.Sprintf("%s: %s", account.Label, category)
		if !health.LastSuccess.IsZero() {
			line += " last-success=" + health.LastSuccess.UTC().Format("2006-01-02T15:04:05Z")
		}
		if health.LastError != "" {
			line += " last-error=" + stablePollCategory(health.LastError)
		}
		line += operationalFields(state, account, now, staleAfter)
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n") + "\n"
}

func Unavailable(accounts []Account) bool {
	for _, account := range accounts {
		if categoryOf(account) != availability.Available {
			return true
		}
	}
	return false
}

func stablePollCategory(category string) string {
	switch category {
	case "transient", "authentication", "rate-limit", "permanent":
		return category
	default:
		return "unknown"
	}
}

func categoryOf(account Account) availability.Category {
	if account.Category == "" {
		return availability.Available
	}
	return account.Category
}
