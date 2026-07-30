package googlecalendar

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
	"golang.org/x/oauth2"
	"google.golang.org/api/calendar/v3"
)

func TestAuthorizerExchangesLoopbackCodeWithRequiredSecurityParameters(t *testing.T) {
	tokenServer := newTokenServer(t, true)
	defer tokenServer.Close()

	var authorizationURL *url.URL
	authorizer := testAuthorizer(tokenServer.URL, func(rawURL string) error {
		var err error
		authorizationURL, err = url.Parse(rawURL)
		if err != nil {
			return err
		}
		query := authorizationURL.Query()
		return callLoopback(query.Get("redirect_uri"), url.Values{
			"state": {query.Get("state")},
			"code":  {"authorization-code"},
		}, nil)
	})

	cfg, token, err := authorizer.Authorize(context.Background(), testCredentialsJSON())
	if err != nil {
		t.Fatal(err)
	}
	if cfg == nil || token == nil || token.RefreshToken != "refresh-token" {
		t.Fatalf("authorization result is incomplete: config=%t token=%#v", cfg != nil, token)
	}
	query := authorizationURL.Query()
	if query.Get("access_type") != "offline" {
		t.Fatalf("access_type = %q", query.Get("access_type"))
	}
	if query.Get("prompt") != "consent" {
		t.Fatalf("prompt = %q", query.Get("prompt"))
	}
	if query.Get("scope") != calendar.CalendarReadonlyScope {
		t.Fatalf("scope = %q, want only %q", query.Get("scope"), calendar.CalendarReadonlyScope)
	}
	redirect, err := url.Parse(query.Get("redirect_uri"))
	if err != nil {
		t.Fatal(err)
	}
	host, _, err := net.SplitHostPort(redirect.Host)
	if err != nil {
		t.Fatal(err)
	}
	if host != "127.0.0.1" || !net.ParseIP(host).IsLoopback() {
		t.Fatalf("loopback listener host = %q", host)
	}
	if redirect.Path != "/oauth2/callback" {
		t.Fatalf("callback path = %q", redirect.Path)
	}
}

func TestAuthorizerRejectsInvalidCallbacks(t *testing.T) {
	tests := map[string]struct {
		callback func(url.Values) url.Values
		kind     SetupErrorKind
	}{
		"state mismatch": {
			callback: func(url.Values) url.Values {
				return url.Values{"state": {"wrong-state"}, "code": {"authorization-code"}}
			},
			kind: SetupStateMismatch,
		},
		"provider error": {
			callback: func(authQuery url.Values) url.Values {
				return url.Values{"state": {authQuery.Get("state")}, "error": {"access_denied"}}
			},
			kind: SetupProviderError,
		},
		"missing code": {
			callback: func(authQuery url.Values) url.Values {
				return url.Values{"state": {authQuery.Get("state")}}
			},
			kind: SetupMissingCode,
		},
	}

	for name, testCase := range tests {
		t.Run(name, func(t *testing.T) {
			tokenServer := newTokenServer(t, true)
			defer tokenServer.Close()
			authorizer := testAuthorizer(tokenServer.URL, func(rawURL string) error {
				authURL, err := url.Parse(rawURL)
				if err != nil {
					return err
				}
				return callLoopback(authURL.Query().Get("redirect_uri"), testCase.callback(authURL.Query()), nil)
			})

			cfg, token, err := authorizer.Authorize(context.Background(), testCredentialsJSON())
			var setupError *SetupError
			if !errors.As(err, &setupError) || setupError.Kind != testCase.kind {
				t.Fatalf("got %T %v", err, err)
			}
			if cfg != nil || token != nil {
				t.Fatalf("rejected callback returned config=%t token=%t", cfg != nil, token != nil)
			}
		})
	}
}

func TestAuthorizerTimesOutWaitingForCallback(t *testing.T) {
	authorizer := Authorizer{
		Browser: BrowserFunc(func(string) error { return nil }),
		Random:  strings.NewReader(strings.Repeat("r", 32)),
		Timeout: 20 * time.Millisecond,
	}

	cfg, token, err := authorizer.Authorize(context.Background(), testCredentialsJSON())
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("got %T %v", err, err)
	}
	if cfg != nil || token != nil {
		t.Fatalf("timeout returned config=%t token=%t", cfg != nil, token != nil)
	}
}

func TestAuthorizerRejectsTokenWithoutRefreshTokenBeforeSuccess(t *testing.T) {
	tokenServer := newTokenServer(t, false)
	defer tokenServer.Close()

	type callbackResult struct {
		status int
		body   string
	}
	callbackResults := make(chan callbackResult, 1)
	authorizer := testAuthorizer(tokenServer.URL, func(rawURL string) error {
		authURL, err := url.Parse(rawURL)
		if err != nil {
			return err
		}
		query := authURL.Query()
		return callLoopback(query.Get("redirect_uri"), url.Values{
			"state": {query.Get("state")},
			"code":  {"authorization-code"},
		}, func(response *http.Response, body []byte) {
			callbackResults <- callbackResult{status: response.StatusCode, body: string(body)}
		})
	})

	cfg, token, err := authorizer.Authorize(context.Background(), testCredentialsJSON())
	var setupError *SetupError
	if !errors.As(err, &setupError) || setupError.Kind != SetupMissingRefreshToken {
		t.Fatalf("got %T %v", err, err)
	}
	if cfg != nil || token != nil {
		t.Fatalf("missing refresh token returned config=%t token=%t", cfg != nil, token != nil)
	}
	var callback callbackResult
	select {
	case callback = <-callbackResults:
	case <-time.After(2 * time.Second):
		t.Fatal("browser did not receive callback response")
	}
	if callback.status == http.StatusOK || strings.Contains(callback.body, "complete") {
		t.Fatalf("callback reported success: status=%d body=%q", callback.status, callback.body)
	}
}

func TestBrowserUsesConfiguredBinaryWithURLAsSoleArgument(t *testing.T) {
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("sh is unavailable")
	}
	output := filepath.Join(t.TempDir(), "arguments")
	marker := filepath.Join(t.TempDir(), "injected")
	script := filepath.Join(t.TempDir(), "browser")
	scriptBody := fmt.Sprintf("#!%s\nprintf '%%s\\n' \"$#\" > %q\nprintf '%%s' \"$1\" >> %q\n", shell, output, output)
	if err := os.WriteFile(script, []byte(scriptBody), 0o700); err != nil {
		t.Fatal(err)
	}
	rawURL := "https://accounts.example.test/auth?value=$(touch%20" + marker + ")"
	browser := NewBrowser(config.Config{BrowserBin: script})
	if err := browser.Open(rawURL); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "1\n"+rawURL {
		t.Fatalf("browser argv = %q", got)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("URL text was evaluated as shell input: %v", err)
	}
}

func TestPersistingTokenSourceUpdatesTokenWithoutChangingAuthorizationMetadata(t *testing.T) {
	store := newTestStore(t)
	bundle := testBundle("generation", "old-access")
	if err := store.SaveAuthorization("alpha", bundle); err != nil {
		t.Fatal(err)
	}
	refreshed := &oauth2.Token{
		AccessToken:  "new-access",
		RefreshToken: "new-refresh",
		TokenType:    "Bearer",
		Expiry:       time.Unix(2_000_000_000, 0).UTC(),
	}
	source := NewPersistingTokenSource(staticTokenSource{token: refreshed}, store, "alpha", bundle)

	gotToken, err := source.Token()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(gotToken, refreshed) {
		t.Fatalf("returned token = %#v", gotToken)
	}
	got, err := store.LoadAuthorization("alpha")
	if err != nil {
		t.Fatal(err)
	}
	want := bundle
	want.Token = *refreshed
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("persisted bundle changed outside token fields:\n got %#v\nwant %#v", got, want)
	}
}

func TestPersistingTokenSourcePreservesRotatedRefreshTokenFromSameGenerationActor(t *testing.T) {
	store := newTestStore(t)
	bundle := testBundle("generation", "old-access")
	if err := store.SaveAuthorization("alpha", bundle); err != nil {
		t.Fatal(err)
	}
	older := NewPersistingTokenSource(staticTokenSource{token: &oauth2.Token{
		AccessToken: "older-access", TokenType: "Bearer",
	}}, store, "alpha", bundle)
	newer := NewPersistingTokenSource(staticTokenSource{token: &oauth2.Token{
		AccessToken: "newer-access", RefreshToken: "rotated-refresh", TokenType: "Bearer",
	}}, store, "alpha", bundle)

	if _, err := newer.Token(); err != nil {
		t.Fatal(err)
	}
	returned, err := older.Token()
	if err != nil {
		t.Fatal(err)
	}
	if returned.RefreshToken != bundle.Token.RefreshToken {
		t.Fatalf("effective returned refresh token = %q", returned.RefreshToken)
	}
	persisted, err := store.LoadAuthorization("alpha")
	if err != nil {
		t.Fatal(err)
	}
	if persisted.Token.AccessToken != "older-access" || persisted.Token.RefreshToken != "rotated-refresh" {
		t.Fatalf("older source overwrote rotated refresh token: %#v", persisted.Token)
	}
}

func TestAuthorizerLeavesUnrelatedPathAndMethodForValidCallback(t *testing.T) {
	tokenServer := newTokenServer(t, true)
	defer tokenServer.Close()
	authorizer := testAuthorizer(tokenServer.URL, func(rawURL string) error {
		authURL, err := url.Parse(rawURL)
		if err != nil {
			return err
		}
		query := authURL.Query()
		redirect := query.Get("redirect_uri")
		response, err := callLoopbackRequest(http.MethodGet, redirect+"/unrelated", nil)
		if err != nil {
			return err
		}
		response.Body.Close()
		if response.StatusCode != http.StatusNotFound {
			return fmt.Errorf("unrelated path status = %d", response.StatusCode)
		}
		response, err = callLoopbackRequest(http.MethodPost, redirect, nil)
		if err != nil {
			return err
		}
		response.Body.Close()
		if response.StatusCode != http.StatusMethodNotAllowed {
			return fmt.Errorf("callback method status = %d", response.StatusCode)
		}
		return callLoopback(redirect, url.Values{
			"state": {query.Get("state")},
			"code":  {"authorization-code"},
		}, nil)
	})

	_, token, err := authorizer.Authorize(context.Background(), testCredentialsJSON())
	if err != nil {
		t.Fatal(err)
	}
	if token == nil || token.RefreshToken != "refresh-token" {
		t.Fatalf("valid callback did not complete authorization: %#v", token)
	}
}

func TestAuthorizerDoesNotOpenBrowserForCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	opened := make(chan struct{}, 1)
	release := make(chan struct{})
	defer close(release)
	authorizer := Authorizer{
		Browser: BrowserFunc(func(string) error {
			opened <- struct{}{}
			<-release
			return nil
		}),
		Random:  strings.NewReader(strings.Repeat("r", 32)),
		Timeout: time.Second,
	}

	_, _, err := authorizer.Authorize(ctx, testCredentialsJSON())
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("got %T %v", err, err)
	}
	select {
	case <-opened:
		t.Fatal("browser opened for canceled context")
	case <-time.After(100 * time.Millisecond):
	}
}

func TestAuthorizerWrapsBrowserError(t *testing.T) {
	browserErr := errors.New("browser unavailable")
	authorizer := Authorizer{
		Browser: BrowserFunc(func(string) error { return browserErr }),
		Random:  strings.NewReader(strings.Repeat("r", 32)),
		Timeout: time.Second,
	}

	_, _, err := authorizer.Authorize(context.Background(), testCredentialsJSON())
	if !errors.Is(err, browserErr) {
		t.Fatalf("browser error was not wrapped: %T %v", err, err)
	}
	if !strings.Contains(err.Error(), "open OAuth authorization URL") {
		t.Fatalf("browser error lacked OAuth context: %v", err)
	}
}

func TestPersistingTokenSourcePropagatesStaleAuthorization(t *testing.T) {
	store := newTestStore(t)
	oldBundle := testBundle("old-generation", "old-access")
	if err := store.SaveAuthorization("alpha", oldBundle); err != nil {
		t.Fatal(err)
	}
	newBundle := testBundle("new-generation", "setup-access")
	newBundle.Identity = "new-person@example.test"
	newBundle.Calendars = []storage.CalendarRef{{ID: "new", Summary: "New"}}
	if err := store.SaveAuthorization("alpha", newBundle); err != nil {
		t.Fatal(err)
	}
	source := NewPersistingTokenSource(staticTokenSource{token: &oauth2.Token{
		AccessToken: "refreshed-access", RefreshToken: "old-refresh", TokenType: "Bearer",
	}}, store, "alpha", oldBundle)

	_, err := source.Token()
	var stale *storage.ErrStaleAuthorization
	if !errors.As(err, &stale) || stale.AccountLabel != "alpha" {
		t.Fatalf("got %T %v", err, err)
	}
	got, loadErr := store.LoadAuthorization("alpha")
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	if !reflect.DeepEqual(got, newBundle) {
		t.Fatalf("stale refresh changed setup bundle:\n got %#v\nwant %#v", got, newBundle)
	}
}

type staticTokenSource struct {
	token *oauth2.Token
}

func (s staticTokenSource) Token() (*oauth2.Token, error) {
	token := *s.token
	return &token, nil
}

func testAuthorizer(tokenURL string, open func(string) error) Authorizer {
	return Authorizer{
		Browser: BrowserFunc(open),
		Random:  strings.NewReader(strings.Repeat("s", 32)),
		Timeout: time.Second,
		Endpoint: oauth2.Endpoint{
			AuthURL:  "https://accounts.example.test/auth",
			TokenURL: tokenURL,
		},
	}
}

func testCredentialsJSON() []byte {
	return []byte(`{"installed":{"client_id":"client-id","client_secret":"client-secret","auth_uri":"https://accounts.example.test/auth","token_uri":"https://oauth2.example.test/token","redirect_uris":["http://127.0.0.1"]}}`)
}

func newTokenServer(t *testing.T, includeRefreshToken bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if err := request.ParseForm(); err != nil {
			t.Error(err)
			http.Error(response, "invalid form", http.StatusBadRequest)
			return
		}
		if request.Form.Get("code") != "authorization-code" {
			t.Errorf("exchange code = %q", request.Form.Get("code"))
		}
		response.Header().Set("Content-Type", "application/json")
		body := map[string]any{
			"access_token": "access-token",
			"token_type":   "Bearer",
			"expires_in":   3600,
		}
		if includeRefreshToken {
			body["refresh_token"] = "refresh-token"
		}
		if err := json.NewEncoder(response).Encode(body); err != nil {
			t.Error(err)
		}
	}))
}

func callLoopback(redirect string, query url.Values, inspect func(*http.Response, []byte)) error {
	callbackURL, err := url.Parse(redirect)
	if err != nil {
		return err
	}
	callbackURL.RawQuery = query.Encode()
	response, err := callLoopbackRequest(http.MethodGet, callbackURL.String(), nil)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	if inspect != nil {
		inspect(response, body)
	}
	return nil
}

func callLoopbackRequest(method, rawURL string, query url.Values) (*http.Response, error) {
	requestURL, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	if query != nil {
		requestURL.RawQuery = query.Encode()
	}
	request, err := http.NewRequest(method, requestURL.String(), nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 2 * time.Second}
	return client.Do(request)
}

func newTestStore(t *testing.T) *storage.Store {
	t.Helper()
	root := t.TempDir()
	store, err := storage.New(storage.Layout{
		DataDir:  filepath.Join(root, "data"),
		StateDir: filepath.Join(root, "state"),
	})
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func testBundle(generation, accessToken string) storage.AuthorizationBundle {
	return storage.AuthorizationBundle{
		Version:     storage.AuthorizationVersion,
		Generation:  generation,
		OAuthClient: json.RawMessage(`{"installed":{"client_id":"client"}}`),
		Token: oauth2.Token{
			AccessToken:  accessToken,
			RefreshToken: "old-refresh",
			TokenType:    "Bearer",
		},
		Identity:  "person@example.test",
		Calendars: []storage.CalendarRef{{ID: "primary", Summary: "Main"}},
	}
}
