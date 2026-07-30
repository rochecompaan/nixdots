package app

import (
	"context"
	"errors"
)

type Category string

const (
	InvalidUsage        Category = "invalid-usage"
	SetupPreparation    Category = "setup-preparation"
	SetupWritePreserved Category = "setup-write-preserved"
	SetupWriteAmbiguous Category = "setup-write-ambiguous"
	RestartRequired     Category = "restart-required"
	NoUsableAccounts    Category = "no-usable-accounts"
	AccountsUnavailable Category = "accounts-unavailable"
	RuntimeFailure      Category = "runtime-failure"
)

type PublicError struct {
	Category Category
	Message  string
	cause    error
}

func (e *PublicError) Error() string { return e.Message }
func (e *PublicError) Unwrap() error { return e.cause }

func publicError(category Category, message string, cause error) error {
	return &PublicError{Category: category, Message: message, cause: cause}
}

func PublicMessage(err error) string {
	var public *PublicError
	if errors.As(err, &public) {
		return public.Message
	}
	return "Operation failed; run meeting-notifier status for redacted account categories."
}

func IsCleanCancellation(err error) bool {
	if err == nil {
		return false
	}
	var public *PublicError
	if errors.As(err, &public) {
		return false
	}
	return containsOnlyCancellation(err)
}

func containsOnlyCancellation(err error) bool {
	if err == context.Canceled {
		return true
	}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		causes := joined.Unwrap()
		if len(causes) == 0 {
			return false
		}
		for _, cause := range causes {
			if !containsOnlyCancellation(cause) {
				return false
			}
		}
		return true
	}
	if wrapped, ok := err.(interface{ Unwrap() error }); ok {
		return containsOnlyCancellation(wrapped.Unwrap())
	}
	return false
}

func publicRunError(err error) error {
	if err == nil || IsCleanCancellation(err) {
		return err
	}
	var public *PublicError
	if errors.As(err, &public) {
		return err
	}
	return publicError(RuntimeFailure, "Operation failed; run meeting-notifier status for redacted account categories.", err)
}
