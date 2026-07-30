package googlecalendar

import (
	"sync"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"golang.org/x/oauth2"
)

type persistingTokenSource struct {
	mu         sync.Mutex
	source     oauth2.TokenSource
	store      *storage.Store
	label      string
	generation string
	current    oauth2.Token
}

func NewPersistingTokenSource(
	source oauth2.TokenSource,
	store *storage.Store,
	accountLabel string,
	bundle storage.AuthorizationBundle,
) oauth2.TokenSource {
	return &persistingTokenSource{
		source:     source,
		store:      store,
		label:      accountLabel,
		generation: bundle.Generation,
		current:    bundle.Token,
	}
}

func (s *persistingTokenSource) Token() (*oauth2.Token, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	token, err := s.source.Token()
	if err != nil {
		return nil, err
	}
	rawCandidate := *token
	effectiveCandidate := rawCandidate
	if effectiveCandidate.RefreshToken == "" {
		effectiveCandidate.RefreshToken = s.current.RefreshToken
	}
	if tokenPersistenceFieldsChanged(s.current, effectiveCandidate) {
		if err := s.store.UpdateToken(s.label, s.generation, rawCandidate); err != nil {
			return nil, err
		}
	}
	s.current = effectiveCandidate
	return &effectiveCandidate, nil
}

func tokenPersistenceFieldsChanged(previous, current oauth2.Token) bool {
	return previous.AccessToken != current.AccessToken ||
		previous.RefreshToken != current.RefreshToken ||
		!sameExpiry(previous.Expiry, current.Expiry)
}

func sameExpiry(left, right time.Time) bool {
	return left.Equal(right)
}
