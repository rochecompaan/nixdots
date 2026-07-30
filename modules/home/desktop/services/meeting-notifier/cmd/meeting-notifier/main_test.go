package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/app"
)

func TestMainReportsJoinedCancellationAndCleanupFailure(t *testing.T) {
	const sentinel = "close-token-sentinel https://acme.zoom.us/j/secret"
	guidance := "Operation failed; run meeting-notifier status for redacted account categories."
	err := errors.Join(context.Canceled, &app.PublicError{Category: app.RuntimeFailure, Message: guidance}, errors.New(sentinel))
	var stderr bytes.Buffer
	if code := reportResult(&stderr, err); code != 1 {
		t.Fatalf("exit code = %d", code)
	}
	if got := stderr.String(); !strings.Contains(got, guidance) || strings.Contains(got, sentinel) || strings.Contains(got, "acme.zoom.us") {
		t.Fatalf("stderr = %q", got)
	}
}

func TestMainKeepsCleanCancellationSilent(t *testing.T) {
	var stderr bytes.Buffer
	if code := reportResult(&stderr, errors.Join(context.Canceled)); code != 0 || stderr.Len() != 0 {
		t.Fatalf("exit code = %d, stderr = %q", code, stderr.String())
	}
}

func TestPublicErrorRenderingPreservesGuidanceWithoutSecretCause(t *testing.T) {
	secret := "token-sentinel credentials-sentinel auth-code-sentinel description-sentinel calendar-id-sentinel https://acme.zoom.us/j/9135550199?source=sentinel"
	err := errors.Join(&app.PublicError{Category: app.RestartRequired, Message: "Authorization is durable; manually restart meeting-notifier.service."}, errors.New(secret))
	got := publicMessage(err)
	if got != "Authorization is durable; manually restart meeting-notifier.service." {
		t.Fatalf("message = %q", got)
	}
	for _, sentinel := range strings.Fields(secret) {
		if strings.Contains(got, sentinel) {
			t.Fatalf("leaked %q in %q", sentinel, got)
		}
	}
}
