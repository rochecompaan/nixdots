package availability

import (
	"errors"
	"fmt"
	"os"
	"testing"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

func TestClassifyUsesTypedAuthorizationAndHealthCategories(t *testing.T) {
	tests := []struct {
		name   string
		err    error
		health storage.Health
		want   Category
	}{
		{name: "available", want: Available},
		{name: "auth required", health: storage.Health{NeedsAuth: true}, want: AuthRequired},
		{name: "missing", err: &storage.OperationError{Stage: storage.StageRead, Err: os.ErrNotExist}, want: Missing},
		{name: "corrupt JSON", err: &storage.CorruptAuthorizationError{Err: errors.New("token-sentinel")}, want: Malformed},
		{name: "malformed bundle", err: &storage.ValidationError{Field: "authorization.token.refreshToken", Value: "token-sentinel"}, want: Malformed},
		{name: "unsupported version", err: &storage.ValidationError{Field: "authorization.version", Value: "99"}, want: UnsupportedVersion},
		{name: "stale authorization", err: &storage.ErrStaleAuthorization{AccountLabel: "alpha"}, want: StaleAuthorization},
		{name: "other IO", err: &storage.OperationError{Stage: storage.StageRead, Err: errors.New("credential-sentinel")}, want: Unavailable},
		{name: "rendered text is irrelevant", err: errors.New("unsupported version missing stale token-sentinel"), want: Unavailable},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			if got := Classify(testCase.err, testCase.health); got != testCase.want {
				t.Fatalf("Classify(%T) = %q, want %q", testCase.err, got, testCase.want)
			}
			if got := fmt.Sprint(testCase.want); got == "token-sentinel" || got == "credential-sentinel" {
				t.Fatalf("category leaked cause: %q", got)
			}
		})
	}
}
