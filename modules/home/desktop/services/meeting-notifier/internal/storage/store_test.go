package storage

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
	"golang.org/x/oauth2"
)

func testStore(t *testing.T) (*Store, Layout) {
	t.Helper()
	root := t.TempDir()
	layout := Layout{
		DataDir:  filepath.Join(root, "data"),
		StateDir: filepath.Join(root, "state"),
	}
	store, err := New(layout)
	if err != nil {
		t.Fatal(err)
	}
	return store, store.layout
}

func testBundle(generation, access string) AuthorizationBundle {
	return AuthorizationBundle{
		Version:     AuthorizationVersion,
		Generation:  generation,
		OAuthClient: json.RawMessage(`{"installed":{"client_id":"client"}}`),
		Token: oauth2.Token{
			AccessToken:  access,
			RefreshToken: "refresh",
			TokenType:    "Bearer",
		},
		Identity:  "person@example.test",
		Calendars: []CalendarRef{{ID: "primary", Summary: "Main"}},
	}
}

func TestStoreUsesPrivatePermissions(t *testing.T) {
	layout := Layout{
		DataDir:  filepath.Join(t.TempDir(), "data"),
		StateDir: filepath.Join(t.TempDir(), "state"),
	}
	store, err := New(layout)
	if err != nil {
		t.Fatal(err)
	}
	state := NewState()
	state.Occurrences["occurrence"] = OccurrenceState{
		Meeting: meeting.Meeting{Key: "occurrence", AccountLabel: "alpha"},
		Phase:   PhaseScheduled,
	}
	if err := store.SaveState(state); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveAuthorization("alpha", testBundle("generation", "access")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{layout.DataDir, layout.StateDir, store.layout.AccountsDir} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o700 {
			t.Fatalf("%s mode is %o", path, info.Mode().Perm())
		}
	}
	for _, path := range []string{
		store.layout.StateFile,
		filepath.Join(store.layout.AccountsDir, "alpha.json"),
		filepath.Join(store.layout.AccountsDir, ".alpha.lock"),
	} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode is %o", path, info.Mode().Perm())
		}
	}
}

func TestAuthorizationUsesOneValidatedFilePerLabel(t *testing.T) {
	store, layout := testStore(t)
	if err := store.SaveAuthorization("alpha-1", testBundle("generation-a", "a")); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveAuthorization("beta", testBundle("generation-b", "b")); err != nil {
		t.Fatal(err)
	}
	for _, label := range []string{"alpha-1", "beta"} {
		if _, err := os.Stat(filepath.Join(layout.AccountsDir, label+".json")); err != nil {
			t.Fatal(err)
		}
	}
	for _, label := range []string{"", ".", "..", ".hidden", "../escape", "a/b", `a\b`} {
		err := store.SaveAuthorization(label, testBundle("generation", "x"))
		var validation *ValidationError
		if !errors.As(err, &validation) || validation.Field != "accountLabel" {
			t.Fatalf("label %q: got %T %v", label, err, err)
		}
	}
}

func TestAuthorizationValidation(t *testing.T) {
	tests := map[string]func(*AuthorizationBundle){
		"version":       func(b *AuthorizationBundle) { b.Version = 2 },
		"generation":    func(b *AuthorizationBundle) { b.Generation = "" },
		"OAuth client":  func(b *AuthorizationBundle) { b.OAuthClient = json.RawMessage(`{"bad"`) },
		"refresh token": func(b *AuthorizationBundle) { b.Token.RefreshToken = "" },
		"identity":      func(b *AuthorizationBundle) { b.Identity = "" },
		"calendars":     func(b *AuthorizationBundle) { b.Calendars = nil },
		"calendar ID":   func(b *AuthorizationBundle) { b.Calendars[0].ID = "" },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			store, _ := testStore(t)
			bundle := testBundle("generation", "access")
			mutate(&bundle)
			var validation *ValidationError
			if err := store.SaveAuthorization("alpha", bundle); !errors.As(err, &validation) {
				t.Fatalf("got %T %v", err, err)
			}
		})
	}
}

func TestAuthorizationReplacementSyncsParentDirectory(t *testing.T) {
	store, _ := testStore(t)
	var mu sync.Mutex
	dirSyncs := 0
	baseOpen := store.ops.open
	store.ops.open = func(path string) (fileHandle, error) {
		file, err := baseOpen(path)
		if err != nil {
			return nil, err
		}
		info, err := file.Stat()
		if err != nil {
			file.Close()
			return nil, err
		}
		if info.IsDir() {
			return &hookFile{fileHandle: file, syncFn: func() error {
				mu.Lock()
				dirSyncs++
				mu.Unlock()
				return file.Sync()
			}}, nil
		}
		return file, nil
	}
	if err := store.SaveAuthorization("alpha", testBundle("generation", "new")); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if dirSyncs != 1 {
		t.Fatalf("parent directory syncs = %d, want 1", dirSyncs)
	}
}

func TestPreRenameFailuresPreservePreviousBundle(t *testing.T) {
	stages := []OperationStage{
		StageTempCreate,
		StageTempChmod,
		StageTempWrite,
		StageTempSync,
		StageTempClose,
		StageRename,
	}
	for _, stage := range stages {
		t.Run(string(stage), func(t *testing.T) {
			store, _ := testStore(t)
			old := testBundle("old-generation", "old")
			if err := store.SaveAuthorization("alpha", old); err != nil {
				t.Fatal(err)
			}
			injected := errors.New("injected failure")
			injectWriteFailure(store, stage, injected)
			err := store.SaveAuthorization("alpha", testBundle("new-generation", "new"))
			assertOperationError(t, err, stage, injected)
			got, err := store.LoadAuthorization("alpha")
			if err != nil {
				t.Fatal(err)
			}
			if got.Generation != old.Generation || got.Token.AccessToken != "old" {
				t.Fatalf("old bundle was replaced: %#v", got)
			}
		})
	}
}

func TestPostRenameFailuresNeverLeavePartialBundle(t *testing.T) {
	for _, stage := range []OperationStage{StageDirectorySync, StageDirectoryClose} {
		t.Run(string(stage), func(t *testing.T) {
			store, _ := testStore(t)
			if err := store.SaveAuthorization("alpha", testBundle("old-generation", "old")); err != nil {
				t.Fatal(err)
			}
			injected := errors.New("injected failure")
			injectWriteFailure(store, stage, injected)
			err := store.SaveAuthorization("alpha", testBundle("new-generation", "new"))
			assertOperationError(t, err, stage, injected)
			got, err := store.LoadAuthorization("alpha")
			if err != nil {
				t.Fatalf("bundle is not complete JSON: %v", err)
			}
			if (got.Generation != "old-generation" || got.Token.AccessToken != "old") &&
				(got.Generation != "new-generation" || got.Token.AccessToken != "new") {
				t.Fatalf("bundle is mixed: %#v", got)
			}
		})
	}
}

func TestDifferentLabelsDoNotShareBundleOrLock(t *testing.T) {
	store, layout := testStore(t)
	baseRename := store.ops.rename
	alphaAtRename := make(chan struct{})
	releaseAlpha := make(chan struct{})
	store.ops.rename = func(oldPath, newPath string) error {
		if newPath == filepath.Join(layout.AccountsDir, "alpha.json") {
			close(alphaAtRename)
			<-releaseAlpha
		}
		return baseRename(oldPath, newPath)
	}
	alphaDone := make(chan error, 1)
	go func() { alphaDone <- store.SaveAuthorization("alpha", testBundle("alpha-generation", "alpha")) }()
	<-alphaAtRename

	betaDone := make(chan error, 1)
	go func() { betaDone <- store.SaveAuthorization("beta", testBundle("beta-generation", "beta")) }()
	select {
	case err := <-betaDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("beta save blocked on alpha lock")
	}
	close(releaseAlpha)
	if err := <-alphaDone; err != nil {
		t.Fatal(err)
	}
	for label, want := range map[string]string{"alpha": "alpha", "beta": "beta"} {
		got, err := store.LoadAuthorization(label)
		if err != nil {
			t.Fatal(err)
		}
		if got.Token.AccessToken != want {
			t.Fatalf("%s bundle contains %q", label, got.Token.AccessToken)
		}
	}
}

func TestUpdateTokenUsesLoadedGeneration(t *testing.T) {
	store, _ := testStore(t)
	original := testBundle("generation", "old")
	if err := store.SaveAuthorization("alpha", original); err != nil {
		t.Fatal(err)
	}
	updated := oauth2.Token{AccessToken: "new", RefreshToken: "refresh", TokenType: "Bearer"}
	if err := store.UpdateToken("alpha", original.Generation, updated); err != nil {
		t.Fatal(err)
	}
	got, err := store.LoadAuthorization("alpha")
	if err != nil {
		t.Fatal(err)
	}
	want := original
	want.Token = updated
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("complete bundle not preserved:\n got %#v\nwant %#v", got, want)
	}
}

func TestStaleRefreshRacingSetupDoesNotOverwriteSetup(t *testing.T) {
	store, layout := testStore(t)
	if err := store.SaveAuthorization("alpha", testBundle("old-generation", "old")); err != nil {
		t.Fatal(err)
	}
	baseRename := store.ops.rename
	setupAtRename := make(chan struct{})
	releaseSetup := make(chan struct{})
	var once sync.Once
	store.ops.rename = func(oldPath, newPath string) error {
		if newPath == filepath.Join(layout.AccountsDir, "alpha.json") {
			once.Do(func() {
				close(setupAtRename)
				<-releaseSetup
			})
		}
		return baseRename(oldPath, newPath)
	}
	setupDone := make(chan error, 1)
	go func() { setupDone <- store.SaveAuthorization("alpha", testBundle("setup-generation", "setup")) }()
	<-setupAtRename
	refreshDone := make(chan error, 1)
	go func() {
		refreshDone <- store.UpdateToken("alpha", "old-generation", oauth2.Token{
			AccessToken: "refresh", RefreshToken: "refresh", TokenType: "Bearer",
		})
	}()
	close(releaseSetup)
	if err := <-setupDone; err != nil {
		t.Fatal(err)
	}
	var stale *ErrStaleAuthorization
	if err := <-refreshDone; !errors.As(err, &stale) || stale.AccountLabel != "alpha" {
		t.Fatalf("got %T %v", err, err)
	}
	got, err := store.LoadAuthorization("alpha")
	if err != nil {
		t.Fatal(err)
	}
	want := testBundle("setup-generation", "setup")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("stale refresh overwrote setup:\n got %#v\nwant %#v", got, want)
	}
}

func TestOwnedJSONReadersAreStrictAndVersioned(t *testing.T) {
	store, layout := testStore(t)
	if err := os.MkdirAll(layout.AccountsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	bundlePath := filepath.Join(layout.AccountsDir, "alpha.json")
	bundleCases := map[string]struct {
		body           string
		wantValidation bool
	}{
		"unknown field": {
			body: `{"version":1,"generation":"g","oauthClient":{"installed":{"client_id":"client"}},"token":{"refresh_token":"r"},"identity":"i","calendars":[{"id":"c","summary":"s"}],"extra":true}`,
		},
		"trailing value": {
			body: `{"version":1,"generation":"g","oauthClient":{"installed":{"client_id":"client"}},"token":{"refresh_token":"r"},"identity":"i","calendars":[{"id":"c","summary":"s"}]} {}`,
		},
		"unsupported version": {
			body:           `{"version":2,"generation":"g","oauthClient":{"installed":{"client_id":"client"}},"token":{"refresh_token":"r"},"identity":"i","calendars":[{"id":"c","summary":"s"}]}`,
			wantValidation: true,
		},
	}
	for name, testCase := range bundleCases {
		t.Run("bundle "+name, func(t *testing.T) {
			body := testCase.body
			if err := os.WriteFile(bundlePath, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := store.LoadAuthorization("alpha"); err == nil {
				t.Fatal("expected strict bundle load failure")
			} else {
				var corrupt *CorruptStateError
				var validation *ValidationError
				var operation *OperationError
				if errors.As(err, &corrupt) || errors.As(err, &operation) {
					t.Fatalf("bundle failure had wrong error category: %T", err)
				}
				if errors.As(err, &validation) != testCase.wantValidation {
					t.Fatalf("bundle validation classification = %t, want %t", errors.As(err, &validation), testCase.wantValidation)
				}
			}
		})
	}

	if err := os.MkdirAll(layout.StateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"unknown field":  `{"version":1,"snapshots":{},"occurrences":{},"authWarnings":{},"health":{},"extra":true}`,
		"trailing value": `{"version":1,"snapshots":{},"occurrences":{},"authWarnings":{},"health":{}} []`,
		"version":        `{"version":2,"snapshots":{},"occurrences":{},"authWarnings":{},"health":{}}`,
	} {
		t.Run("state "+name, func(t *testing.T) {
			if err := os.WriteFile(layout.StateFile, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err := store.LoadState()
			var corrupt *CorruptStateError
			if !errors.As(err, &corrupt) || corrupt.Path != layout.StateFile {
				t.Fatalf("got %T %v", err, err)
			}
			if _, statErr := os.Stat(layout.StateFile); statErr != nil {
				t.Fatalf("storage quarantined state before application policy: %v", statErr)
			}
		})
	}
}

func TestStateIOFailuresAreNotCorruption(t *testing.T) {
	t.Run("read", func(t *testing.T) {
		store, layout := testStore(t)
		sentinel := errors.New("permission denied")
		store.ops.open = func(string) (fileHandle, error) { return nil, sentinel }
		_, err := store.LoadState()
		assertNonCorruptOperationError(t, err, StageRead, layout.StateFile, sentinel)
	})

	t.Run("read close", func(t *testing.T) {
		store, layout := testStore(t)
		if err := store.SaveState(NewState()); err != nil {
			t.Fatal(err)
		}
		sentinel := errors.New("close failure")
		baseOpen := store.ops.open
		store.ops.open = func(path string) (fileHandle, error) {
			file, err := baseOpen(path)
			if err != nil {
				return nil, err
			}
			return &hookFile{fileHandle: file, closeFn: func() error {
				if err := file.Close(); err != nil {
					return err
				}
				return sentinel
			}}, nil
		}
		_, err := store.LoadState()
		assertNonCorruptOperationError(t, err, StageReadClose, layout.StateFile, sentinel)
	})

	t.Run("temporary file permission", func(t *testing.T) {
		store, layout := testStore(t)
		sentinel := errors.New("chmod failure")
		injectWriteFailure(store, StageTempChmod, sentinel)
		err := store.SaveState(NewState())
		assertNonCorruptOperationError(t, err, StageTempChmod, layout.StateFile, sentinel)
	})
}

func TestOccurrenceValidationRejectsImpossiblePhaseFields(t *testing.T) {
	now := time.Now().UTC()
	base := meeting.Meeting{Key: "occurrence", AccountLabel: "alpha"}
	tests := map[string]OccurrenceState{
		"unknown phase":          {Meeting: base, Phase: Phase("mystery")},
		"scheduled with ID":      {Meeting: base, Phase: PhaseScheduled, NotificationID: 1},
		"notify with action":     {Meeting: base, Phase: PhaseNotifyPending, ActionExpiresAt: now},
		"notified without ID":    {Meeting: base, Phase: PhaseNotified, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)},
		"history without expiry": {Meeting: base, Phase: PhaseActionableHistory, NotificationID: 1, NotifiedAt: now},
		"join without resume":    {Meeting: base, Phase: PhaseJoinPending, NotificationID: 1, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now},
		"joined with action":     {Meeting: base, Phase: PhaseJoined, JoinedAt: now, NotificationID: 1},
		"close without reason":   {Meeting: base, Phase: PhaseClosePending, NotificationID: 1},
	}
	for name, occurrence := range tests {
		t.Run(name, func(t *testing.T) {
			var validation *ValidationError
			if err := occurrence.Validate(); !errors.As(err, &validation) {
				t.Fatalf("got %T %v", err, err)
			}
		})
	}
}

func TestOccurrenceValidationAcceptsEveryPhase(t *testing.T) {
	now := time.Now().UTC()
	base := meeting.Meeting{Key: "occurrence", AccountLabel: "alpha"}
	valid := []OccurrenceState{
		{Meeting: base, Phase: PhaseScheduled},
		{Meeting: base, Phase: PhaseNotifyPending, NotificationID: 7, NotBefore: now, Attempt: 1},
		{Meeting: base, Phase: PhaseNotified, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)},
		{Meeting: base, Phase: PhaseActionableHistory, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour)},
		{Meeting: base, Phase: PhaseJoinPending, NotificationID: 7, NotifiedAt: now, ActionExpiresAt: now.Add(time.Hour), JoinRequestedAt: now, ResumePhase: PhaseNotified, JoinRevision: 1},
		{Meeting: base, Phase: PhaseJoined, JoinedAt: now, JoinRevision: 1},
		{Meeting: base, Phase: PhaseClosePending, NotificationID: 7, CloseReason: CloseCancelled},
	}
	for _, occurrence := range valid {
		if err := occurrence.Validate(); err != nil {
			t.Fatalf("phase %q: %v", occurrence.Phase, err)
		}
	}
}

func TestClosePendingResumePhaseRequiresReschedule(t *testing.T) {
	base := OccurrenceState{
		Meeting:        meeting.Meeting{Key: "occurrence", AccountLabel: "alpha"},
		Phase:          PhaseClosePending,
		NotificationID: 7,
	}
	for _, reason := range []CloseReason{
		CloseCancelled,
		CloseDeleted,
		CloseDeclined,
		CloseURLRemoved,
		CloseRescheduled,
		CloseExpired,
	} {
		for _, resume := range []Phase{"", PhaseScheduled, PhaseNotifyPending, PhaseJoined} {
			t.Run(string(reason)+"/"+string(resume), func(t *testing.T) {
				occurrence := base
				occurrence.CloseReason = reason
				occurrence.ResumePhase = resume
				err := occurrence.Validate()
				allowed := resume == "" || (reason == CloseRescheduled && (resume == PhaseScheduled || resume == PhaseNotifyPending))
				if allowed && err != nil {
					t.Fatalf("resume phase %q unexpectedly rejected: %v", resume, err)
				}
				if !allowed {
					var validation *ValidationError
					if !errors.As(err, &validation) || validation.Field != "resumePhase" {
						t.Fatalf("resume phase %q got %T %v", resume, err, err)
					}
				}
			})
		}
	}
}

func TestStateValidatesAggregateKeysAndNotificationIDs(t *testing.T) {
	state := NewState()
	state.Occurrences["wrong"] = OccurrenceState{Meeting: meeting.Meeting{Key: "actual", AccountLabel: "alpha"}, Phase: PhaseScheduled}
	var validation *ValidationError
	if err := state.Validate(); !errors.As(err, &validation) || validation.Field != "occurrences.key" {
		t.Fatalf("got %T %v", err, err)
	}

	state = NewState()
	for _, key := range []string{"one", "two"} {
		state.Occurrences[key] = OccurrenceState{
			Meeting: meeting.Meeting{Key: key, AccountLabel: "alpha"}, Phase: PhaseNotified,
			NotificationID: 42, NotifiedAt: time.Now(), ActionExpiresAt: time.Now().Add(time.Hour),
		}
	}
	if err := state.Validate(); !errors.As(err, &validation) || validation.Field != "occurrences.notificationId" {
		t.Fatalf("got %T %v", err, err)
	}
}

func TestNotificationIndexIsDerivedAndNotPersisted(t *testing.T) {
	store, layout := testStore(t)
	state := NewState()
	state.Occurrences["one"] = OccurrenceState{
		Meeting: meeting.Meeting{Key: "one", AccountLabel: "alpha"}, Phase: PhaseNotified,
		NotificationID: 42, NotifiedAt: time.Now(), ActionExpiresAt: time.Now().Add(time.Hour),
	}
	state.Occurrences["two"] = OccurrenceState{
		Meeting: meeting.Meeting{Key: "two", AccountLabel: "alpha"}, Phase: PhaseScheduled,
	}
	index, err := state.NotificationIndex()
	if err != nil {
		t.Fatal(err)
	}
	if len(index) != 1 || index[42] != "one" {
		t.Fatalf("index = %#v", index)
	}
	if err := store.SaveState(state); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(layout.StateFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) == "" || json.Valid(data) == false {
		t.Fatalf("invalid state JSON %q", data)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	if _, exists := raw["notificationIndex"]; exists {
		t.Fatal("derived notification index was persisted")
	}
	loaded, err := store.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	loadedIndex, err := loaded.NotificationIndex()
	if err != nil || loadedIndex[42] != "one" {
		t.Fatalf("loaded index = %#v, err = %v", loadedIndex, err)
	}
}

func TestLoadMissingStateReturnsNewState(t *testing.T) {
	store, _ := testStore(t)
	state, err := store.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	if state.Version != StateVersion || state.Snapshots == nil || state.Occurrences == nil || state.AuthWarnings == nil || state.Health == nil {
		t.Fatalf("state not initialized: %#v", state)
	}
}

func injectWriteFailure(store *Store, stage OperationStage, injected error) {
	switch stage {
	case StageTempCreate:
		store.ops.createTemp = func(string, string) (fileHandle, error) { return nil, injected }
	case StageTempChmod, StageTempWrite, StageTempSync, StageTempClose:
		baseCreate := store.ops.createTemp
		store.ops.createTemp = func(dir, pattern string) (fileHandle, error) {
			file, err := baseCreate(dir, pattern)
			if err != nil {
				return nil, err
			}
			hooked := &hookFile{fileHandle: file}
			if stage == StageTempChmod {
				hooked.chmodFn = func(os.FileMode) error { return injected }
			} else if stage == StageTempWrite {
				hooked.writeFn = func([]byte) (int, error) { return 0, injected }
			} else if stage == StageTempSync {
				hooked.syncFn = func() error { return injected }
			} else {
				hooked.closeFn = func() error {
					if err := file.Close(); err != nil {
						return err
					}
					return injected
				}
			}
			return hooked, nil
		}
	case StageRename:
		store.ops.rename = func(string, string) error { return injected }
	case StageDirectorySync, StageDirectoryClose:
		baseOpen := store.ops.open
		store.ops.open = func(path string) (fileHandle, error) {
			file, err := baseOpen(path)
			if err != nil {
				return nil, err
			}
			info, err := file.Stat()
			if err != nil || !info.IsDir() {
				return file, err
			}
			hooked := &hookFile{fileHandle: file}
			if stage == StageDirectorySync {
				hooked.syncFn = func() error { return injected }
			} else {
				hooked.closeFn = func() error {
					if err := file.Close(); err != nil {
						return err
					}
					return injected
				}
			}
			return hooked, nil
		}
	}
}

type hookFile struct {
	fileHandle
	chmodFn func(os.FileMode) error
	writeFn func([]byte) (int, error)
	syncFn  func() error
	closeFn func() error
}

func (f *hookFile) Chmod(mode os.FileMode) error {
	if f.chmodFn != nil {
		return f.chmodFn(mode)
	}
	return f.fileHandle.Chmod(mode)
}

func (f *hookFile) Write(data []byte) (int, error) {
	if f.writeFn != nil {
		return f.writeFn(data)
	}
	return f.fileHandle.Write(data)
}

func (f *hookFile) Sync() error {
	if f.syncFn != nil {
		return f.syncFn()
	}
	return f.fileHandle.Sync()
}

func (f *hookFile) Close() error {
	if f.closeFn != nil {
		return f.closeFn()
	}
	return f.fileHandle.Close()
}

func assertOperationError(t *testing.T, err error, stage OperationStage, cause error) {
	t.Helper()
	var operation *OperationError
	if !errors.As(err, &operation) || operation.Stage != stage || !errors.Is(err, cause) {
		t.Fatalf("got %T %v, want stage %q wrapping injected error", err, err, stage)
	}
}

func assertNonCorruptOperationError(t *testing.T, err error, stage OperationStage, path string, cause error) {
	t.Helper()
	var corrupt *CorruptStateError
	if errors.As(err, &corrupt) {
		t.Fatalf("I/O error mislabeled corruption: %v", err)
	}
	var operation *OperationError
	if !errors.As(err, &operation) || operation.Stage != stage || operation.Path != path || !errors.Is(err, cause) {
		t.Fatalf("got %T %v, want path %q stage %q", err, err, path, stage)
	}
}
