package storage

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"golang.org/x/oauth2"
)

const AuthorizationVersion = 1

var safeAccountLabel = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)

type CalendarRef struct {
	ID      string `json:"id"`
	Summary string `json:"summary"`
}

type AuthorizationBundle struct {
	Version     int             `json:"version"`
	Generation  string          `json:"generation"`
	OAuthClient json.RawMessage `json:"oauthClient"`
	Token       oauth2.Token    `json:"token"`
	Identity    string          `json:"identity"`
	Calendars   []CalendarRef   `json:"calendars"`
}

type ErrStaleAuthorization struct {
	AccountLabel string
}

func (e *ErrStaleAuthorization) Error() string {
	return "authorization generation changed for " + e.AccountLabel
}

type CorruptAuthorizationError struct {
	Err error
}

func (e *CorruptAuthorizationError) Error() string { return "corrupt authorization bundle" }
func (e *CorruptAuthorizationError) Unwrap() error { return e.Err }

func validateAccountLabel(label string) error {
	if !safeAccountLabel.MatchString(label) {
		return &ValidationError{Field: "accountLabel", Value: label}
	}
	return nil
}

func (b AuthorizationBundle) Validate() error {
	if b.Version != AuthorizationVersion {
		return &ValidationError{Field: "authorization.version", Value: fmt.Sprint(b.Version)}
	}
	if strings.TrimSpace(b.Generation) == "" {
		return invalidField("authorization.generation")
	}
	if len(b.OAuthClient) == 0 || !json.Valid(b.OAuthClient) {
		return invalidField("authorization.oauthClient")
	}
	var client map[string]json.RawMessage
	if err := json.Unmarshal(b.OAuthClient, &client); err != nil || len(client) == 0 {
		return invalidField("authorization.oauthClient")
	}
	if b.Token.RefreshToken == "" {
		return invalidField("authorization.token.refreshToken")
	}
	if strings.TrimSpace(b.Identity) == "" {
		return invalidField("authorization.identity")
	}
	if len(b.Calendars) == 0 {
		return invalidField("authorization.calendars")
	}
	seen := make(map[string]struct{}, len(b.Calendars))
	for _, calendar := range b.Calendars {
		if strings.TrimSpace(calendar.ID) == "" {
			return invalidField("authorization.calendars.id")
		}
		if _, exists := seen[calendar.ID]; exists {
			return &ValidationError{Field: "authorization.calendars.id", Value: calendar.ID}
		}
		seen[calendar.ID] = struct{}{}
	}
	return nil
}

func (s *Store) SaveAuthorization(label string, bundle AuthorizationBundle) error {
	if err := validateAccountLabel(label); err != nil {
		return err
	}
	if err := bundle.Validate(); err != nil {
		return err
	}
	return s.withAccountLock(label, func() error {
		return s.saveAuthorizationUnlocked(label, bundle)
	})
}

func (s *Store) LoadAuthorization(label string) (AuthorizationBundle, error) {
	if err := validateAccountLabel(label); err != nil {
		return AuthorizationBundle{}, err
	}
	return s.loadAuthorizationUnlocked(label)
}

func (s *Store) UpdateToken(label, loadedGeneration string, token oauth2.Token) error {
	if err := validateAccountLabel(label); err != nil {
		return err
	}
	return s.withAccountLock(label, func() error {
		bundle, err := s.loadAuthorizationUnlocked(label)
		if err != nil {
			return err
		}
		if bundle.Generation != loadedGeneration {
			return &ErrStaleAuthorization{AccountLabel: label}
		}
		if token.RefreshToken == "" {
			token.RefreshToken = bundle.Token.RefreshToken
		}
		bundle.Token = token
		if err := bundle.Validate(); err != nil {
			return err
		}
		return s.saveAuthorizationUnlocked(label, bundle)
	})
}

func (s *Store) saveAuthorizationUnlocked(label string, bundle AuthorizationBundle) error {
	data, err := json.Marshal(bundle)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return atomicWrite(s.ops, s.authorizationPath(label), data)
}

func (s *Store) loadAuthorizationUnlocked(label string) (AuthorizationBundle, error) {
	path := s.authorizationPath(label)
	data, err := readFile(s.ops, path)
	if err != nil {
		return AuthorizationBundle{}, err
	}
	var bundle AuthorizationBundle
	if err := decodeStrict(data, &bundle); err != nil {
		return AuthorizationBundle{}, &CorruptAuthorizationError{Err: err}
	}
	if err := bundle.Validate(); err != nil {
		return AuthorizationBundle{}, err
	}
	return bundle, nil
}

func (s *Store) authorizationPath(label string) string {
	return filepath.Join(s.layout.AccountsDir, label+".json")
}

func (s *Store) withAccountLock(label string, action func() error) error {
	lockPath := filepath.Join(s.layout.AccountsDir, "."+label+".lock")
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return operationError(StageLockOpen, lockPath, err)
	}
	if err := lock.Chmod(0o600); err != nil {
		_ = lock.Close()
		return operationError(StageLockOpen, lockPath, err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		_ = lock.Close()
		return operationError(StageLock, lockPath, err)
	}
	actionErr := action()
	unlockErr := syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	closeErr := lock.Close()
	if actionErr != nil {
		return actionErr
	}
	if unlockErr != nil {
		return operationError(StageUnlock, lockPath, unlockErr)
	}
	if closeErr != nil {
		return operationError(StageUnlock, lockPath, closeErr)
	}
	return nil
}
