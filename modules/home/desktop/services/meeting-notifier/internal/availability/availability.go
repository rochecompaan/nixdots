package availability

import (
	"errors"
	"os"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type Category string

const (
	Available          Category = "available"
	Missing            Category = "missing"
	Malformed          Category = "malformed"
	UnsupportedVersion Category = "unsupported-version"
	StaleAuthorization Category = "stale-authorization"
	AuthRequired       Category = "auth-required"
	Unavailable        Category = "unavailable"
)

func Classify(err error, health storage.Health, loadedGeneration ...string) Category {
	if err == nil {
		generationMatches := len(loadedGeneration) == 0 || (health.AuthorizationGeneration != "" && health.AuthorizationGeneration == loadedGeneration[0])
		if health.NeedsAuth && generationMatches {
			return AuthRequired
		}
		return Available
	}
	if errors.Is(err, os.ErrNotExist) {
		return Missing
	}
	var corrupt *storage.CorruptAuthorizationError
	if errors.As(err, &corrupt) {
		return Malformed
	}
	var validation *storage.ValidationError
	if errors.As(err, &validation) {
		if validation.Field == "authorization.version" {
			return UnsupportedVersion
		}
		return Malformed
	}
	var stale *storage.ErrStaleAuthorization
	if errors.As(err, &stale) {
		return StaleAuthorization
	}
	return Unavailable
}
