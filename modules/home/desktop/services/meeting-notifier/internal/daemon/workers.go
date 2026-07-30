package daemon

import (
	"context"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type PollCommand struct {
	AccountLabel string
	Bundle       storage.AuthorizationBundle
	Start        time.Time
	End          time.Time
}

const (
	pollDeadline     = 30 * time.Second
	activityDeadline = 5 * time.Second
	launcherDeadline = 20 * time.Second
)

func RunPollWorker(ctx context.Context, source Source, commands <-chan PollCommand, events chan<- Event) {
	for {
		select {
		case <-ctx.Done():
			return
		case command, ok := <-commands:
			if !ok {
				return
			}
			call, cancel := context.WithTimeout(ctx, pollDeadline)
			result, err := source.SyncAccount(call, command.AccountLabel, command.Bundle, command.Start, command.End)
			cancel()
			result.AccountLabel = command.AccountLabel
			result.AuthorizationGeneration = command.Bundle.Generation
			result.Err = err
			result.Meetings = append([]meeting.Meeting(nil), result.Meetings...)
			result.Observations = append([]meeting.Observation(nil), result.Observations...)
			event := Event{Kind: PollResultEvent, At: time.Now().UTC(), Poll: &result}
			select {
			case events <- event:
			case <-ctx.Done():
				return
			}
		}
	}
}

func RunActivityWorker(ctx context.Context, reader Activity, commands <-chan struct{}, events chan<- Event) {
	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-commands:
			if !ok {
				return
			}
			call, cancel := context.WithTimeout(ctx, activityDeadline)
			result, err := reader.Current(call)
			cancel()
			event := Event{Kind: ActivityResultEvent, At: time.Now().UTC(), Activity: &ActivityResult{CheckedAt: time.Now().UTC(), Result: result, Err: err}}
			select {
			case events <- event:
			case <-ctx.Done():
				return
			}
		}
	}
}

func RunLauncherWorker(ctx context.Context, client Launcher, commands <-chan Effect, events chan<- Event) {
	for {
		select {
		case <-ctx.Done():
			return
		case command, ok := <-commands:
			if !ok {
				return
			}
			call, cancel := context.WithTimeout(ctx, launcherDeadline)
			err := client.Open(call, command.AccountLabel, command.URL)
			cancel()
			if ctx.Err() != nil {
				return
			}
			event := Event{Kind: LaunchResultEvent, At: time.Now().UTC(), Launch: &LaunchResult{OccurrenceKey: command.OccurrenceKey, AccountLabel: command.AccountLabel, JoinRevision: command.JoinRevision, Err: err}}
			select {
			case events <- event:
			case <-ctx.Done():
				return
			}
		}
	}
}
