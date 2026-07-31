package googlecalendar

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"sync/atomic"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
	"google.golang.org/api/calendar/v3"
)

const callbackPath = "/oauth2/callback"

type Browser interface {
	Open(rawURL string) error
}

type BrowserFunc func(string) error

func (f BrowserFunc) Open(rawURL string) error { return f(rawURL) }

type Authorizer struct {
	Browser  Browser
	Random   io.Reader
	Timeout  time.Duration
	Endpoint oauth2.Endpoint
}

type SetupErrorKind string

const (
	SetupStateMismatch       SetupErrorKind = "OAuth state mismatch"
	SetupProviderError       SetupErrorKind = "OAuth provider rejected authorization"
	SetupMissingCode         SetupErrorKind = "OAuth callback omitted the authorization code"
	SetupMissingRefreshToken SetupErrorKind = "OAuth provider omitted the refresh token"
)

type SetupError struct {
	Kind SetupErrorKind
}

func (e *SetupError) Error() string {
	return "OAuth setup failed: " + string(e.Kind)
}

type commandBrowser struct {
	binary string
}

func NewBrowser(cfg config.Config) Browser {
	return commandBrowser{binary: cfg.BrowserBin}
}

func (b commandBrowser) Open(rawURL string) error {
	if err := exec.Command(b.binary, rawURL).Run(); err != nil {
		return fmt.Errorf("open authorization URL: %w", err)
	}
	return nil
}

type authorizationResult struct {
	token *oauth2.Token
	err   error
}

func (a Authorizer) Authorize(ctx context.Context, credentialsJSON []byte) (*oauth2.Config, *oauth2.Token, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, fmt.Errorf("start OAuth authorization: %w", err)
	}
	cfg, err := google.ConfigFromJSON(credentialsJSON, calendar.CalendarReadonlyScope)
	if err != nil {
		return nil, nil, fmt.Errorf("parse OAuth client: %w", err)
	}
	if a.Browser == nil {
		return nil, nil, errors.New("OAuth browser is required")
	}
	if a.Random == nil {
		return nil, nil, errors.New("OAuth random source is required")
	}
	if a.Timeout <= 0 {
		return nil, nil, errors.New("OAuth timeout must be positive")
	}
	if a.Endpoint != (oauth2.Endpoint{}) {
		cfg.Endpoint = a.Endpoint
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, nil, fmt.Errorf("listen for OAuth callback: %w", err)
	}
	cfg.RedirectURL = "http://" + listener.Addr().String() + callbackPath
	stateBytes := make([]byte, 32)
	if _, err := io.ReadFull(a.Random, stateBytes); err != nil {
		_ = listener.Close()
		return nil, nil, fmt.Errorf("generate OAuth state: %w", err)
	}
	state := base64.RawURLEncoding.EncodeToString(stateBytes)
	authURL := cfg.AuthCodeURL(
		state,
		oauth2.AccessTypeOffline,
		oauth2.SetAuthURLParam("prompt", "consent"),
	)

	flowCtx, cancel := context.WithTimeout(ctx, a.Timeout)
	defer cancel()
	results := make(chan authorizationResult, 1)
	var handled atomic.Bool
	callbackHandler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet {
			http.Error(response, "OAuth callback requires GET.", http.StatusMethodNotAllowed)
			return
		}
		if !handled.CompareAndSwap(false, true) {
			http.Error(response, "OAuth callback already handled.", http.StatusConflict)
			return
		}
		_ = listener.Close()
		result := exchangeCallback(flowCtx, cfg, state, request)
		if result.err != nil {
			writeCallbackResponse(response, http.StatusBadRequest, "Authorization failed.\n")
		} else {
			writeCallbackResponse(response, http.StatusOK, "Authorization complete. You can close this window.\n")
		}
		select {
		case results <- result:
		case <-flowCtx.Done():
		}
	})
	mux := http.NewServeMux()
	mux.Handle(callbackPath, callbackHandler)
	server := &http.Server{Handler: mux}
	defer server.Close()
	defer listener.Close()
	serveDone := make(chan error, 1)
	go func() { serveDone <- server.Serve(listener) }()
	browserDone := make(chan error, 1)
	go func() { browserDone <- a.Browser.Open(authURL) }()

	for {
		select {
		case result := <-results:
			if err := server.Shutdown(flowCtx); err != nil && !errors.Is(err, net.ErrClosed) {
				return nil, nil, fmt.Errorf("shut down OAuth callback server: %w", err)
			}
			if result.err != nil {
				return nil, nil, result.err
			}
			return cfg, result.token, nil
		case err := <-browserDone:
			if err != nil {
				return nil, nil, fmt.Errorf("open OAuth authorization URL: %w", err)
			}
			browserDone = nil
		case err := <-serveDone:
			if err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, net.ErrClosed) && flowCtx.Err() == nil {
				return nil, nil, fmt.Errorf("serve OAuth callback: %w", err)
			}
			serveDone = nil
		case <-flowCtx.Done():
			return nil, nil, fmt.Errorf("wait for OAuth callback: %w", flowCtx.Err())
		}
	}
}

func exchangeCallback(ctx context.Context, cfg *oauth2.Config, state string, request *http.Request) authorizationResult {
	providedState := request.URL.Query().Get("state")
	if subtle.ConstantTimeCompare([]byte(providedState), []byte(state)) != 1 {
		return authorizationResult{err: &SetupError{Kind: SetupStateMismatch}}
	}
	if request.URL.Query().Get("error") != "" {
		return authorizationResult{err: &SetupError{Kind: SetupProviderError}}
	}
	code := request.URL.Query().Get("code")
	if code == "" {
		return authorizationResult{err: &SetupError{Kind: SetupMissingCode}}
	}
	token, err := cfg.Exchange(ctx, code)
	if err != nil {
		return authorizationResult{err: fmt.Errorf("exchange OAuth code: %w", err)}
	}
	if token.RefreshToken == "" {
		return authorizationResult{err: &SetupError{Kind: SetupMissingRefreshToken}}
	}
	return authorizationResult{token: token}
}

func writeCallbackResponse(response http.ResponseWriter, status int, body string) {
	response.Header().Set("Content-Type", "text/plain; charset=utf-8")
	response.WriteHeader(status)
	_, _ = io.WriteString(response, body)
	if flusher, ok := response.(http.Flusher); ok {
		flusher.Flush()
	}
}
