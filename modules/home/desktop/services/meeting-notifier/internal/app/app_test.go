package app

import (
	"context"
	"errors"
	"testing"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/googlecalendar"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type preparer struct {
	bundle storage.AuthorizationBundle
	err    error
}

func (p preparer) Prepare(context.Context, string, []byte) (googlecalendar.PreparedSetup, error) {
	return googlecalendar.PreparedSetup{Bundle: p.bundle}, p.err
}

type authStore struct {
	saved int
	err   error
}

func (s *authStore) SaveAuthorization(string, storage.AuthorizationBundle) error {
	s.saved++
	return s.err
}

type restart struct {
	calls int
	err   error
}

func (r *restart) Restart(context.Context) error { r.calls++; return r.err }
func TestSetupSavesBeforeRestart(t *testing.T) {
	store := &authStore{}
	service := &restart{}
	a := App{Setup: preparer{}, Store: store, Service: service}
	if err := a.SetupAccount(context.Background(), "alpha", []byte("creds")); err != nil {
		t.Fatal(err)
	}
	if store.saved != 1 || service.calls != 1 {
		t.Fatalf("saved=%d restart=%d", store.saved, service.calls)
	}
}
func TestSetupDoesNotRestartWhenWriteFails(t *testing.T) {
	store := &authStore{err: errors.New("write")}
	service := &restart{}
	a := App{Setup: preparer{}, Store: store, Service: service}
	if a.SetupAccount(context.Background(), "alpha", nil) == nil {
		t.Fatal("accepted write failure")
	}
	if service.calls != 0 {
		t.Fatal("restarted before durable save")
	}
}
