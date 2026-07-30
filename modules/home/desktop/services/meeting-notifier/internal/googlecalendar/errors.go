package googlecalendar

import (
	"context"
	"errors"
	"net"
	"net/http"

	"golang.org/x/oauth2"
	"google.golang.org/api/googleapi"
)

type ErrorKind string

const (
	ErrorAuthentication ErrorKind = "authentication"
	ErrorRateLimit      ErrorKind = "rate-limit"
	ErrorTransient      ErrorKind = "transient"
	ErrorCancellation   ErrorKind = "cancellation"
	ErrorPermanent      ErrorKind = "permanent"
)

func ClassifyError(err error) ErrorKind {
	if errors.Is(err, context.Canceled) {
		return ErrorCancellation
	}
	var retrieveErr *oauth2.RetrieveError
	if errors.As(err, &retrieveErr) && retrieveErr.ErrorCode == "invalid_grant" {
		return ErrorAuthentication
	}
	var apiErr *googleapi.Error
	if errors.As(err, &apiErr) {
		if apiErr.Code == http.StatusUnauthorized || hasReason(apiErr, "authError", "invalidCredentials") {
			return ErrorAuthentication
		}
		if apiErr.Code == http.StatusTooManyRequests ||
			apiErr.Code == http.StatusForbidden && hasReason(apiErr, "rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded") {
			return ErrorRateLimit
		}
		if apiErr.Code >= http.StatusInternalServerError && apiErr.Code <= 599 {
			return ErrorTransient
		}
		return ErrorPermanent
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return ErrorTransient
	}
	return ErrorPermanent
}

func hasReason(apiErr *googleapi.Error, reasons ...string) bool {
	for _, item := range apiErr.Errors {
		for _, reason := range reasons {
			if item.Reason == reason {
				return true
			}
		}
	}
	return false
}
