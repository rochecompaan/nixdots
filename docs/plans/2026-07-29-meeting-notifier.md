# Meeting Notifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Nix-managed Go daemon that synchronizes allowlisted calendars from three Google accounts, sends a Noctalia Join notification five minutes before Meet or Zoom events on the recently active host, and opens the meeting in the mapped Firefox profile on Niri workspace `5`.

**Architecture:** A focused meeting-notifier Go module owns OAuth, Calendar polling, one atomic authorization bundle per account, and a single state-owning event loop with one lifecycle aggregate per occurrence. Polling, notification, and launch workers return immutable events; only the reducer persists state. Niri owns one separate canonical Firefox launcher executable used by both profile startup and meeting joins.

**Tech Stack:** Go 1.26, `google.golang.org/api/calendar/v3`, `golang.org/x/oauth2`, `github.com/godbus/dbus/v5`, Nix `buildGoModule`, Home Manager systemd user services, Noctalia freedesktop notifications, Niri IPC, Firefox.

**Design reference:** `docs/specs/2026-07-29-meeting-notifier-design.md`

## Global Constraints

- Request only the Google Calendar `calendar.readonly` OAuth scope; use offline access with `prompt=consent` and reject authorization responses without a refresh token.
- Persist one versioned authorization bundle per account label; OAuth client, token, identity, calendars, and generation change through one atomic replacement.
- Keep account identities, calendar IDs, OAuth material, event snapshots, and notification state outside the repository and Nix store.
- Use stable account labels only: `upfront`, `sixfeetup`, and `alpha`.
- Map profiles exactly: `upfront -> default`, `sixfeetup -> sixfeetup`, `alpha -> clubhouse`.
- Poll every `1m`, cache a `24h` horizon, and notify when `0 < start-now <= 5m`.
- Accept only HTTPS URLs for `meet.google.com`, `zoom.us`, and subdomains of `zoom.us`; reject URL user information.
- Never pass event text or URLs through a shell.
- Persist every lifecycle transition before dispatching its external effect; DBus and worker events use cancellable blocking delivery into the always-draining state owner.
- Use Google event identity plus `recurringEventId`/`originalStartTime`, never mutable current start time, for occurrence identity.
- Strict at-most-once delivery is not available across an ambiguous freedesktop Notify crash; document the bounded at-least-once duplicate window.
- Run on both `roche@kiptum` and `roche@kipchoge`; logind activity gating is host-local and fails open with a degraded warning.
- Route only the newly created matching Firefox window to named Niri workspace `5` through the same canonical launcher used by profile startup.
- Keep Go files focused by responsibility; split a file before it grows beyond roughly 250 lines unless cohesion clearly favors keeping it together.
- Production behavior changes follow TDD. Static Nix values and documentation use direct formatting, evaluation, and build verification rather than dedicated content tests.
- Use signed Conventional Commits and never bypass hooks.

## Planned File Structure

```text
modules/home/desktop/services/meeting-notifier/
├── README.md                         # OAuth setup, account setup, status, rollback, smoke test
├── default.nix                       # Home Manager options, generated config, package, user service
├── package.nix                       # buildGoModule derivation
├── go.mod                            # pinned Go module dependencies
├── go.sum
├── cmd/meeting-notifier/
│   └── main.go                       # process entry point only
└── internal/
    ├── activity/
    │   ├── logind.go                 # logind session eligibility
    │   └── logind_test.go
    ├── app/
    │   ├── app.go                    # setup/run/status dependency wiring
    │   └── app_test.go
    ├── config/
    │   ├── config.go                 # trusted static JSON config and XDG config path
    │   └── config_test.go
    ├── daemon/
    │   ├── daemon.go                 # one-owner event loop and worker coordination
    │   ├── daemon_test.go
    │   ├── reducer.go                # lifecycle transitions and effect derivation
    │   ├── reducer_test.go
    │   ├── retry.go                  # per-account bounded retry state
    │   └── retry_test.go
    ├── googlecalendar/
    │   ├── client.go                 # CalendarList and Events adapters
    │   ├── client_test.go
    │   ├── oauth.go                  # loopback OAuth and refresh-token persistence
    │   ├── oauth_test.go
    │   ├── setup.go                  # identity confirmation and calendar selection
    │   └── setup_test.go
    ├── launcher/
    │   ├── client.go                 # validated direct-argv shared-launcher invocation
    │   └── client_test.go
    ├── meeting/
    │   ├── meeting.go                # normalized meeting and occurrence identity
    │   ├── meeting_test.go
    │   ├── url.go                    # URL extraction and allowlist validation
    │   └── url_test.go
    ├── notifications/
    │   ├── client.go                 # freedesktop Notify/CloseNotification client
    │   ├── client_test.go
    │   ├── signals.go                # ActionInvoked and NotificationClosed decoding
    │   └── signals_test.go
    ├── status/
    │   ├── status.go                 # redacted status rendering
    │   └── status_test.go
    └── storage/
        ├── layout.go                 # XDG paths and private directory creation
        ├── layout_test.go
        ├── store.go                  # atomic authorization bundles and daemon state
        └── store_test.go

modules/home/desktop/wayland/niri/firefox-launcher/
├── package.nix                       # canonical stdlib-only Go launcher package
├── go.mod
├── cmd/niri-firefox-launcher/main.go
└── internal/launcher/
    ├── launcher.go                   # startup and meeting launch modes
    ├── launcher_test.go
    ├── niri.go                       # one typed Niri placement implementation
    └── niri_test.go
```

Existing files modified:

- `modules/home/desktop/services/default.nix`
- `modules/home/desktop/wayland/niri/config/autostart.nix`
- `modules/home/desktop/wayland/niri/config/firefox-profiles.sh` (reduce to a trusted static dispatcher)
- `home/roche/kiptum.nix`
- `home/roche/kipchoge.nix`

---

### Task 1: Establish the Go module and trusted static configuration

**Files:**
- Create: `modules/home/desktop/services/meeting-notifier/go.mod`
- Create: `modules/home/desktop/services/meeting-notifier/internal/config/config.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/config/config_test.go`

**Interfaces:**
- Produces: `config.Config`, `config.Account`, `config.Load(path string) (Config, error)`, and `config.DefaultPath() (string, error)`.
- Consumes: only the Go standard library.

- [ ] **Step 1: Initialize the nested Go module**

Run:

```sh
cd modules/home/desktop/services/meeting-notifier
go mod init github.com/rochecompaan/nixdots/meeting-notifier
```

Expected: `go.mod` declares the module and the installed Go toolchain version; no source outside this directory changes.

- [ ] **Step 2: Write failing configuration tests**

Create `internal/config/config_test.go` with table-driven coverage for successful duration parsing, missing accounts, empty profiles, non-HTTPS host patterns, and default XDG config path:

```go
package config

import (
    "os"
    "path/filepath"
    "testing"
    "time"
)

func TestLoadParsesTrustedConfig(t *testing.T) {
    t.Setenv("XDG_CONFIG_HOME", t.TempDir())
    path := filepath.Join(t.TempDir(), "config.json")
    data := `{
      "pollInterval":"1m",
      "leadTime":"5m",
      "horizon":"24h",
      "workspace":"5",
      "allowedHosts":["meet.google.com","zoom.us","*.zoom.us"],
      "browserBin":"/nix/store/xdg-utils/bin/xdg-open",
      "firefoxLauncherBin":"/nix/store/niri-firefox-launcher/bin/niri-firefox-launcher",
      "systemctlBin":"/nix/store/systemd/bin/systemctl",
      "accounts":{"alpha":{"firefoxProfile":"clubhouse"}}
    }`
    if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
        t.Fatal(err)
    }

    got, err := Load(path)
    if err != nil {
        t.Fatal(err)
    }
    if got.PollInterval != time.Minute || got.LeadTime != 5*time.Minute || got.Horizon != 24*time.Hour {
        t.Fatalf("unexpected durations: %#v", got)
    }
    if got.Accounts["alpha"].FirefoxProfile != "clubhouse" {
        t.Fatalf("unexpected account mapping: %#v", got.Accounts)
    }
}

func TestLoadRejectsInvalidConfig(t *testing.T) {
    tests := []struct {
        name string
        body string
    }{
        {"no accounts", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{}}`},
        {"empty profile", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{"alpha":{"firefoxProfile":""}}}`},
        {"bad host pattern", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["https://meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{"alpha":{"firefoxProfile":"clubhouse"}}}`},
        {"unknown field", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{"alpha":{"firefoxProfile":"clubhouse"}},"unexpected":true}`},
        {"trailing JSON", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{"alpha":{"firefoxProfile":"clubhouse"}}}{}`},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            path := filepath.Join(t.TempDir(), "config.json")
            if err := os.WriteFile(path, []byte(tt.body), 0o600); err != nil {
                t.Fatal(err)
            }
            if _, err := Load(path); err == nil {
                t.Fatal("expected validation error")
            }
        })
    }
}

func TestDefaultPathUsesXDGConfigHome(t *testing.T) {
    root := t.TempDir()
    t.Setenv("XDG_CONFIG_HOME", root)
    got, err := DefaultPath()
    if err != nil {
        t.Fatal(err)
    }
    want := filepath.Join(root, "meeting-notifier", "config.json")
    if got != want {
        t.Fatalf("got %q, want %q", got, want)
    }
}
```

- [ ] **Step 3: Run the focused tests and confirm RED**

Run:

```sh
go test ./internal/config
```

Expected: FAIL because `Config`, `Load`, and `DefaultPath` do not exist.

- [ ] **Step 4: Implement configuration loading and validation**

Create `internal/config/config.go` with these public types and behavior:

```go
package config

import (
    "bytes"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "os"
    "path/filepath"
    "strings"
    "time"
)

type Account struct {
    FirefoxProfile string `json:"firefoxProfile"`
}

type fileConfig struct {
    PollInterval string             `json:"pollInterval"`
    LeadTime     string             `json:"leadTime"`
    Horizon      string             `json:"horizon"`
    Workspace    string             `json:"workspace"`
    AllowedHosts []string           `json:"allowedHosts"`
    BrowserBin   string             `json:"browserBin"`
    FirefoxLauncherBin string       `json:"firefoxLauncherBin"`
    SystemctlBin string             `json:"systemctlBin"`
    Accounts     map[string]Account `json:"accounts"`
}

type Config struct {
    PollInterval time.Duration
    LeadTime     time.Duration
    Horizon      time.Duration
    Workspace    string
    AllowedHosts []string
    BrowserBin   string
    FirefoxLauncherBin string
    SystemctlBin string
    Accounts     map[string]Account
}

func DefaultPath() (string, error) {
    root := os.Getenv("XDG_CONFIG_HOME")
    if root == "" {
        home, err := os.UserHomeDir()
        if err != nil {
            return "", err
        }
        root = filepath.Join(home, ".config")
    }
    return filepath.Join(root, "meeting-notifier", "config.json"), nil
}

func Load(path string) (Config, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        return Config{}, err
    }
    var raw fileConfig
    decoder := json.NewDecoder(bytes.NewReader(data))
    decoder.DisallowUnknownFields()
    if err := decoder.Decode(&raw); err != nil {
        return Config{}, fmt.Errorf("decode static config: %w", err)
    }
    var trailing any
    if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
        return Config{}, errors.New("static config must contain exactly one JSON value")
    }
    poll, err := time.ParseDuration(raw.PollInterval)
    if err != nil || poll <= 0 {
        return Config{}, errors.New("pollInterval must be a positive Go duration")
    }
    lead, err := time.ParseDuration(raw.LeadTime)
    if err != nil || lead <= 0 {
        return Config{}, errors.New("leadTime must be a positive Go duration")
    }
    horizon, err := time.ParseDuration(raw.Horizon)
    if err != nil || horizon < lead {
        return Config{}, errors.New("horizon must be a duration at least as large as leadTime")
    }
    if raw.Workspace == "" || raw.BrowserBin == "" || raw.FirefoxLauncherBin == "" || raw.SystemctlBin == "" {
        return Config{}, errors.New("workspace, browserBin, firefoxLauncherBin, and systemctlBin are required")
    }
    if len(raw.Accounts) == 0 {
        return Config{}, errors.New("at least one account mapping is required")
    }
    for label, account := range raw.Accounts {
        if label == "" || account.FirefoxProfile == "" {
            return Config{}, errors.New("account labels and Firefox profiles must be non-empty")
        }
    }
    if len(raw.AllowedHosts) == 0 {
        return Config{}, errors.New("allowedHosts must not be empty")
    }
    for _, host := range raw.AllowedHosts {
        trimmed := strings.TrimPrefix(host, "*.")
        if trimmed == "" || strings.ContainsAny(trimmed, "/:@") {
            return Config{}, fmt.Errorf("invalid host pattern %q", host)
        }
    }
    return Config{
        PollInterval: poll,
        LeadTime: lead,
        Horizon: horizon,
        Workspace: raw.Workspace,
        AllowedHosts: append([]string(nil), raw.AllowedHosts...),
        BrowserBin: raw.BrowserBin,
        FirefoxLauncherBin: raw.FirefoxLauncherBin,
        SystemctlBin: raw.SystemctlBin,
        Accounts: raw.Accounts,
    }, nil
}
```

- [ ] **Step 5: Run tests and formatting**

Run:

```sh
gofmt -w internal/config
go test ./internal/config
```

Expected: PASS.

- [ ] **Step 6: Commit the configuration foundation**

```sh
git add modules/home/desktop/services/meeting-notifier/go.mod \
  modules/home/desktop/services/meeting-notifier/internal/config
git commit -m "feat(calendar): add meeting notifier configuration"
```

---

### Task 2: Normalize events and select safe meeting URLs

**Files:**
- Create: `modules/home/desktop/services/meeting-notifier/internal/meeting/meeting.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/meeting/meeting_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/meeting/url.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/meeting/url_test.go`

**Interfaces:**
- Produces: `meeting.Candidate`, `meeting.Meeting`, `meeting.Normalize`, `meeting.Due`, `meeting.ValidateURL`, and `meeting.OccurrenceKey(account, calendarID, eventID, recurringEventID string, originalStart time.Time) (string, error)`.
- Consumes: `config.Config.AllowedHosts` and the standard library.

- [ ] **Step 1: Write failing URL policy tests**

Create `internal/meeting/url_test.go` covering structured precedence, Zoom subdomains, HTML descriptions, and rejection:

```go
package meeting

import "testing"

func TestSelectURLPrecedence(t *testing.T) {
    c := Candidate{
        ConferenceURLs: []string{"https://meet.google.com/abc-defg-hij"},
        HangoutLink: "https://meet.google.com/mno-pqrs-tuv",
        Location: "https://sixfeetup.zoom.us/j/123",
    }
    got, err := selectURL(c, []string{"meet.google.com", "zoom.us", "*.zoom.us"})
    if err != nil {
        t.Fatal(err)
    }
    if got != "https://meet.google.com/abc-defg-hij" {
        t.Fatalf("got %q", got)
    }
}

func TestExtractsZoomFromHTMLDescription(t *testing.T) {
    c := Candidate{Description: `<a href="https://sixfeetup.zoom.us/j/123?source=a&amp;b=c">Join</a>`}
    got, err := selectURL(c, []string{"meet.google.com", "zoom.us", "*.zoom.us"})
    if err != nil {
        t.Fatal(err)
    }
    if got != "https://sixfeetup.zoom.us/j/123?source=a&b=c" {
        t.Fatalf("got %q", got)
    }
}

func TestValidateURLRejectsUnsafeInputs(t *testing.T) {
    inputs := []string{
        "http://meet.google.com/abc",
        "https://user@meet.google.com/abc",
        "https://meet.google.com.evil.example/abc",
        "https://zoom.us.evil.example/j/123",
        "javascript:alert(1)",
    }
    for _, input := range inputs {
        if _, err := ValidateURL(input, []string{"meet.google.com", "zoom.us", "*.zoom.us"}); err == nil {
            t.Fatalf("expected %q to be rejected", input)
        }
    }
}
```

- [ ] **Step 2: Write failing normalization and timing tests**

Create `internal/meeting/meeting_test.go`:

```go
package meeting

import (
    "testing"
    "time"
)

func TestNormalizeAndDue(t *testing.T) {
    now := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
    c := Candidate{
        AccountLabel: "alpha",
        CalendarID: "team",
        CalendarName: "Team",
        EventID: "event-1",
        Summary: "Standup",
        Start: now.Add(5 * time.Minute),
        End: now.Add(35 * time.Minute),
        ConferenceURLs: []string{"https://meet.google.com/abc-defg-hij"},
    }
    got, ok, err := Normalize(c, []string{"meet.google.com", "zoom.us", "*.zoom.us"})
    if err != nil || !ok {
        t.Fatalf("got ok=%v err=%v", ok, err)
    }
    if !Due(got, now, 5*time.Minute) {
        t.Fatal("meeting should be due")
    }
    if got.Key == "" || got.AccountLabel != "alpha" {
        t.Fatalf("unexpected meeting: %#v", got)
    }
}

func TestOccurrenceKeyIsStableAcrossRescheduling(t *testing.T) {
    original := time.Date(2026, 7, 29, 9, 0, 0, 0, time.UTC)
    base := Candidate{
        AccountLabel: "alpha", CalendarID: "team", EventID: "event-1",
        Summary: "Standup", Start: original,
        HangoutLink: "https://meet.google.com/abc-defg-hij",
    }
    moved := base
    moved.Start = original.Add(30 * time.Minute)
    first, ok, err := Normalize(base, []string{"meet.google.com"})
    if err != nil || !ok {
        t.Fatalf("normalize original: ok=%v err=%v", ok, err)
    }
    second, ok, err := Normalize(moved, []string{"meet.google.com"})
    if err != nil || !ok {
        t.Fatalf("normalize moved: ok=%v err=%v", ok, err)
    }
    if first.Key != second.Key {
        t.Fatalf("non-recurring key changed: %q != %q", first.Key, second.Key)
    }

    base.RecurringEventID = "series-1"
    base.OriginalStart = original
    moved = base
    moved.Start = original.Add(45 * time.Minute)
    first, _, err = Normalize(base, []string{"meet.google.com"})
    if err != nil {
        t.Fatal(err)
    }
    second, _, err = Normalize(moved, []string{"meet.google.com"})
    if err != nil {
        t.Fatal(err)
    }
    if first.Key != second.Key {
        t.Fatalf("recurring key changed: %q != %q", first.Key, second.Key)
    }
}

func TestNormalizeRejectsRecurringInstanceWithoutOriginalStart(t *testing.T) {
    candidate := Candidate{
        AccountLabel: "alpha", CalendarID: "team", EventID: "instance-1",
        RecurringEventID: "series-1", Start: time.Now().Add(time.Hour),
        HangoutLink: "https://meet.google.com/abc-defg-hij",
    }
    if _, _, err := Normalize(candidate, []string{"meet.google.com"}); err == nil {
        t.Fatal("expected missing original start to fail")
    }
}

func TestNormalizeSkipsNonMeetingEvents(t *testing.T) {
    base := Candidate{
        AccountLabel: "alpha", CalendarID: "team", EventID: "event-1",
        Start: time.Now().Add(time.Hour), HangoutLink: "https://meet.google.com/abc-defg-hij",
    }
    tests := []Candidate{
        func() Candidate { c := base; c.Cancelled = true; return c }(),
        func() Candidate { c := base; c.Declined = true; return c }(),
        func() Candidate { c := base; c.AllDay = true; return c }(),
        func() Candidate { c := base; c.HangoutLink = ""; return c }(),
    }
    for _, candidate := range tests {
        if _, ok, err := Normalize(candidate, []string{"meet.google.com"}); err != nil || ok {
            t.Fatalf("expected skip, got ok=%v err=%v candidate=%#v", ok, err, candidate)
        }
    }
}
```

- [ ] **Step 3: Run tests and confirm RED**

Run:

```sh
go test ./internal/meeting
```

Expected: FAIL because the meeting package does not exist.

- [ ] **Step 4: Implement normalized types, URL policy, identity, and timing**

Create `meeting.go` with these exact public shapes:

```go
package meeting

import (
    "crypto/sha256"
    "encoding/hex"
    "errors"
    "strings"
    "time"
)

type Candidate struct {
    AccountLabel  string
    CalendarID    string
    CalendarName  string
    EventID         string
    RecurringEventID string
    OriginalStart   time.Time
    Summary         string
    Start           time.Time
    End             time.Time
    AllDay        bool
    Cancelled     bool
    Declined      bool
    ConferenceURLs []string
    HangoutLink   string
    Location      string
    Description   string
}

type Meeting struct {
    Key          string    `json:"key"`
    AccountLabel string    `json:"accountLabel"`
    CalendarID   string    `json:"calendarId"`
    CalendarName string    `json:"calendarName"`
    EventID         string    `json:"eventId"`
    RecurringEventID string    `json:"recurringEventId,omitempty"`
    OriginalStart   time.Time `json:"originalStart,omitempty"`
    Summary         string    `json:"summary"`
    Start           time.Time `json:"start"`
    End          time.Time `json:"end"`
    URL          string    `json:"url"`
}

func OccurrenceKey(account, calendarID, eventID, recurringEventID string, originalStart time.Time) (string, error) {
    if account == "" || calendarID == "" || eventID == "" {
        return "", errors.New("account, calendar ID, and event ID are required")
    }
    stableEventID := eventID
    instance := ""
    if recurringEventID != "" {
        if originalStart.IsZero() {
            return "", errors.New("recurring instances require original start time")
        }
        stableEventID = recurringEventID
        instance = originalStart.UTC().Format(time.RFC3339Nano)
    }
    raw := strings.Join([]string{account, calendarID, stableEventID, instance}, "\x00")
    sum := sha256.Sum256([]byte(raw))
    return hex.EncodeToString(sum[:]), nil
}

func Normalize(c Candidate, allowedHosts []string) (Meeting, bool, error) {
    if c.Cancelled || c.Declined || c.AllDay || c.Start.IsZero() {
        return Meeting{}, false, nil
    }
    rawURL, err := selectURL(c, allowedHosts)
    if err != nil {
        return Meeting{}, false, nil
    }
    key, err := OccurrenceKey(c.AccountLabel, c.CalendarID, c.EventID, c.RecurringEventID, c.OriginalStart)
    if err != nil {
        return Meeting{}, false, err
    }
    return Meeting{
        Key: key,
        AccountLabel: c.AccountLabel,
        CalendarID: c.CalendarID,
        CalendarName: c.CalendarName,
        EventID: c.EventID,
        RecurringEventID: c.RecurringEventID,
        OriginalStart: c.OriginalStart,
        Summary: c.Summary,
        Start: c.Start,
        End: c.End,
        URL: rawURL,
    }, true, nil
}

func Due(m Meeting, now time.Time, lead time.Duration) bool {
    delta := m.Start.Sub(now)
    return delta > 0 && delta <= lead
}
```

Create `url.go` using `html.UnescapeString`, `net/url`, and a compiled HTTPS URL expression. `ValidateURL` must lowercase and trim a terminal dot from the hostname, enforce exact hosts or true subdomains for `*.` patterns, reject `u.User != nil`, and return `u.String()`. `selectURL` must try conference URLs, then `HangoutLink`, then extracted location URLs, then extracted description URLs, returning the first valid URL.

- [ ] **Step 5: Run meeting tests and the race detector**

Run:

```sh
gofmt -w internal/meeting
go test -race ./internal/meeting
```

Expected: PASS, including rejection of lookalike domains.

- [ ] **Step 6: Commit meeting selection**

```sh
git add modules/home/desktop/services/meeting-notifier/internal/meeting
git commit -m "feat(calendar): select supported meeting events"
```

---

### Task 3: Add atomic authorization bundles and validated lifecycle state

**Files:**
- Modify: `modules/home/desktop/services/meeting-notifier/go.mod`
- Create: `modules/home/desktop/services/meeting-notifier/go.sum`
- Create: `modules/home/desktop/services/meeting-notifier/internal/storage/layout.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/storage/layout_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/storage/store.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/storage/store_test.go`

**Interfaces:**
- Produces: `storage.Layout`, `storage.Store`, `storage.AuthorizationBundle`, `storage.ErrStaleAuthorization`, `storage.State`, `storage.OccurrenceState`, `storage.Phase`, `storage.CloseReason`, and `storage.State.NotificationIndex()`.
- Consumes: `meeting.Meeting` and `golang.org/x/oauth2.Token`.

- [ ] **Step 1: Add OAuth token types and write failing storage tests**

Run:

```sh
cd modules/home/desktop/services/meeting-notifier
go get golang.org/x/oauth2@v0.36.0
```

Then test:

- XDG fallback paths, `0700` directories, and `0600` files;
- one bundle file per validated account label;
- atomic replacement plus parent-directory fsync;
- failures before rename preserving the previous complete bundle, and injected sync/close failures after rename allowing either old or new complete bundle but never partial JSON;
- different labels never touching the same bundle or lock;
- a refresh update using the loaded generation;
- a stale-generation refresh racing setup and returning `ErrStaleAuthorization` without overwriting setup;
- strict JSON decoding and unsupported bundle/state versions;
- corrupt-state quarantine versus fail-fast permission/read/sync/close/rename errors;
- rejection of impossible lifecycle field/phase combinations;
- deterministic derivation of notification ID to occurrence key.

Use this core permission assertion:

```go
func TestStoreUsesPrivatePermissions(t *testing.T) {
    layout := Layout{
        DataDir: filepath.Join(t.TempDir(), "data"),
        StateDir: filepath.Join(t.TempDir(), "state"),
    }
    store, err := New(layout)
    if err != nil {
        t.Fatal(err)
    }
    state := NewState()
    state.Occurrences["occurrence"] = OccurrenceState{
        Meeting: meeting.Meeting{Key: "occurrence", AccountLabel: "alpha"},
        Phase: PhaseScheduled,
    }
    if err := store.SaveState(state); err != nil {
        t.Fatal(err)
    }
    for _, path := range []string{layout.DataDir, layout.StateDir} {
        info, err := os.Stat(path)
        if err != nil {
            t.Fatal(err)
        }
        if info.Mode().Perm() != 0o700 {
            t.Fatalf("%s mode is %o", path, info.Mode().Perm())
        }
    }
}
```

- [ ] **Step 2: Run storage tests and confirm RED**

Run:

```sh
go test ./internal/storage
```

Expected: FAIL because bundle and lifecycle types do not exist.

- [ ] **Step 3: Implement one aggregate per account and occurrence**

Use these public types consistently:

```go
const AuthorizationVersion = 1

type Layout struct {
    ConfigFile string
    DataDir    string
    StateDir   string
    AccountsDir string
    StateFile  string
}

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

type Snapshot struct {
    FetchedAt time.Time         `json:"fetchedAt"`
    Meetings  []meeting.Meeting `json:"meetings"`
}

type Health struct {
    LastSuccess time.Time `json:"lastSuccess"`
    LastError   string    `json:"lastError,omitempty"`
    NeedsAuth   bool      `json:"needsAuth"`
}

type Phase string

const (
    PhaseScheduled         Phase = "scheduled"
    PhaseNotifyPending     Phase = "notify-pending"
    PhaseNotified          Phase = "notified"
    PhaseActionableHistory Phase = "actionable-history"
    PhaseJoinPending       Phase = "join-pending"
    PhaseJoined            Phase = "joined"
    PhaseClosePending      Phase = "close-pending"
)

type CloseReason string

const (
    CloseCancelled   CloseReason = "cancelled"
    CloseDeleted     CloseReason = "deleted"
    CloseDeclined    CloseReason = "declined"
    CloseURLRemoved  CloseReason = "url-removed"
    CloseRescheduled CloseReason = "rescheduled"
    CloseExpired     CloseReason = "expired"
)

type OccurrenceState struct {
    Meeting         meeting.Meeting `json:"meeting"`
    Phase           Phase           `json:"phase"`
    NotificationID  uint32          `json:"notificationId,omitempty"`
    NotifiedAt      time.Time       `json:"notifiedAt,omitempty"`
    ActionExpiresAt time.Time       `json:"actionExpiresAt,omitempty"`
    NotBefore       time.Time       `json:"notBefore,omitempty"`
    Attempt         int             `json:"attempt,omitempty"`
    JoinRequestedAt time.Time       `json:"joinRequestedAt,omitempty"`
    JoinedAt        time.Time       `json:"joinedAt,omitempty"`
    CloseReason     CloseReason     `json:"closeReason,omitempty"`
    ResumePhase     Phase           `json:"resumePhase,omitempty"`
}

type State struct {
    Version      int                        `json:"version"`
    Snapshots    map[string]Snapshot        `json:"snapshots"`
    Occurrences  map[string]OccurrenceState `json:"occurrences"`
    AuthWarnings map[string]time.Time       `json:"authWarnings"`
    Health       map[string]Health          `json:"health"`
}
```

`SaveAuthorization(label, bundle)` validates a safe label, version, non-empty random generation, refresh token, identity, calendars, and OAuth client JSON; acquires only `<AccountsDir>/.<label>.lock`; and atomically replaces `<AccountsDir>/<label>.json`. `UpdateToken(label, loadedGeneration, token)` acquires the same lock, strictly reloads the current bundle, compares generations, and either atomically rewrites the complete bundle with the new token or returns `ErrStaleAuthorization`. This lock covers only one read-check-write and replaces all global marker/transaction machinery.

`OccurrenceState.Validate` defines the allowed fields for each phase. `State.Validate` checks map key equals `Meeting.Key` and rejects duplicate non-zero notification IDs. `NotificationIndex` derives `map[uint32]string` from validated aggregates and is rebuilt after load/transition; it is never persisted.

All owned JSON readers use `json.Decoder.DisallowUnknownFields()` and require EOF. Atomic writes sync/close the temporary file, rename it, then fsync/close the parent directory. Errors carry an operation stage: pre-rename failures preserve the old file; post-rename failures are durability-ambiguous and tests accept old or new complete content but reject partial/mixed content. Only a typed state decoding/validation `CorruptStateError` is quarantined at the application boundary; bundle decoding/version errors and all non-corruption I/O errors propagate.

- [ ] **Step 4: Run focused tests**

Run:

```sh
gofmt -w internal/storage
go test -race ./internal/storage
```

Expected: PASS, including stale-generation and cross-label race tests.

- [ ] **Step 5: Commit bundle and lifecycle storage**

```sh
git add modules/home/desktop/services/meeting-notifier/go.mod \
  modules/home/desktop/services/meeting-notifier/go.sum \
  modules/home/desktop/services/meeting-notifier/internal/storage
git commit -m "feat(calendar): persist notifier bundles and state"
```

---

### Task 4: Implement loopback OAuth and refresh-token persistence

**Files:**
- Modify: `modules/home/desktop/services/meeting-notifier/go.mod`
- Modify: `modules/home/desktop/services/meeting-notifier/go.sum`
- Create: `modules/home/desktop/services/meeting-notifier/internal/googlecalendar/oauth.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/googlecalendar/oauth_test.go`
- Modify: `modules/home/desktop/services/meeting-notifier/internal/storage/store.go`
- Modify: `modules/home/desktop/services/meeting-notifier/internal/storage/store_test.go`

**Interfaces:**
- Produces: `googlecalendar.Authorizer.Authorize(ctx, credentialsJSON) (*oauth2.Config, *oauth2.Token, error)` and `googlecalendar.NewPersistingTokenSource`.
- Consumes: `storage.Store.UpdateToken`, `storage.AuthorizationBundle.Generation`, `calendar.CalendarReadonlyScope`, and a direct-argv `Browser` interface.

- [ ] **Step 1: Add pinned Google dependencies**

Run:

```sh
cd modules/home/desktop/services/meeting-notifier
go get google.golang.org/api@v0.291.0
```

Expected: `go.mod` and `go.sum` retain OAuth `v0.36.0`, add Google API `v0.291.0`, and pin transitive dependencies.

- [ ] **Step 2: Write failing loopback OAuth tests**

Use an `httptest.Server` as the token endpoint and an injected browser function that calls the generated loopback callback. Cover a successful exchange, state mismatch, provider error, timeout, binding to `127.0.0.1`, and a successful token response that omits `refresh_token`. The success test must assert `access_type=offline` and `prompt=consent` are present in the authorization URL and the returned refresh token is non-empty. The missing-refresh-token test must assert authorization fails before producing a prepared bundle.

Define the seam exactly:

```go
type Browser interface {
    Open(rawURL string) error
}

type BrowserFunc func(string) error

func (f BrowserFunc) Open(rawURL string) error { return f(rawURL) }

type Authorizer struct {
    Browser Browser
    Random  io.Reader
    Timeout time.Duration
    Endpoint oauth2.Endpoint
}
```

- [ ] **Step 3: Run OAuth tests and confirm RED**

Run:

```sh
go test ./internal/googlecalendar -run 'TestAuthorizer|TestPersistingTokenSource'
```

Expected: FAIL because OAuth types do not exist.

- [ ] **Step 4: Implement the installed-app loopback flow**

Implementation requirements:

```go
cfg, err := google.ConfigFromJSON(credentialsJSON, calendar.CalendarReadonlyScope)
if err != nil {
    return nil, nil, fmt.Errorf("parse OAuth client: %w", err)
}
ln, err := net.Listen("tcp", "127.0.0.1:0")
if err != nil {
    return nil, nil, fmt.Errorf("listen for OAuth callback: %w", err)
}
cfg.RedirectURL = "http://" + ln.Addr().String() + "/oauth2/callback"
stateBytes := make([]byte, 32)
if _, err := io.ReadFull(a.Random, stateBytes); err != nil {
    return nil, nil, fmt.Errorf("generate OAuth state: %w", err)
}
state := base64.RawURLEncoding.EncodeToString(stateBytes)
authURL := cfg.AuthCodeURL(
    state,
    oauth2.AccessTypeOffline,
    oauth2.SetAuthURLParam("prompt", "consent"),
)
```

Serve exactly one callback, compare state with `subtle.ConstantTimeCompare`, reject `error` and missing `code`, and exchange under the timeout context. Reject `token.RefreshToken == ""` with a typed setup error before returning a token or writing a success response. When `Authorizer.Endpoint` is non-zero, assign it to `cfg.Endpoint` so tests use the fake token server. Write the completion response only after a valid refresh token is present, then shut down the listener. Open the authorization URL as direct argv through a production browser implementation that executes trusted `config.Config.BrowserBin` with `<URL>` as its sole argument and never invokes a shell.

Implement `persistingTokenSource.Token()` with account label and loaded bundle generation. When access token, refresh token, or expiry changes, call `Store.UpdateToken(label, generation, token)`. Propagate `ErrStaleAuthorization` so an old daemon cannot overwrite a setup bundle; never retry with rendered errors or log token values.

- [ ] **Step 5: Test generation-checked token persistence**

Test a refresh against the current generation updates only the token fields while preserving OAuth client, identity, and calendars. Then race a blocked old-generation refresh with `SaveAuthorization` for a new generation: after setup wins the per-label lock, the old refresh must return `ErrStaleAuthorization` and the complete new bundle must remain byte-for-byte equivalent after decoding. Run:

```sh
gofmt -w internal/googlecalendar internal/storage
go test -race ./internal/googlecalendar ./internal/storage
```

Expected: PASS.

- [ ] **Step 6: Commit OAuth support**

```sh
git add modules/home/desktop/services/meeting-notifier/go.mod \
  modules/home/desktop/services/meeting-notifier/go.sum \
  modules/home/desktop/services/meeting-notifier/internal/googlecalendar \
  modules/home/desktop/services/meeting-notifier/internal/storage
git commit -m "feat(calendar): authorize meeting notifier accounts"
```

---

### Task 5: Add Google Calendar setup and event polling

**Files:**
- Create: `modules/home/desktop/services/meeting-notifier/internal/googlecalendar/client.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/googlecalendar/client_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/googlecalendar/setup.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/googlecalendar/setup_test.go`

**Interfaces:**
- Produces: `googlecalendar.Client.ListCalendars`, `googlecalendar.Client.ListCandidates`, `googlecalendar.Setup.Prepare`, `googlecalendar.PreparedSetup`, and `googlecalendar.ErrorKind`.
- Consumes: `meeting.Candidate`, `storage.AuthorizationBundle`, `storage.CalendarRef`, OAuth credentials/tokens, and Google Calendar generated types.

- [ ] **Step 1: Write failing paginated-client tests**

Construct the generated service with `option.WithEndpoint(server.URL + "/")` and `option.WithHTTPClient(server.Client())`. The fake server must assert:

```text
singleEvents=true
orderBy=startTime
timeMin=<RFC3339>
timeMax=<RFC3339>
```

Return two pages and include:

- a moved recurring instance with `recurringEventId`, stable `originalStartTime`, and changed `dateTime` start/end;
- a cancelled event;
- an all-day event with `date`;
- a self attendee whose `responseStatus` is `declined`;
- structured video `conferenceData`;
- `hangoutLink`, location, and description fields.

Assert the adapter emits `meeting.Candidate` values without applying URL/timing policy; copies `RecurringEventID`; parses `OriginalStartTime`; and sets `AllDay`, `Cancelled`, and `Declined` correctly. A recurring instance with an absent or malformed original start must return a contextual decoding error rather than silently using the mutable start.

- [ ] **Step 2: Write failing setup-selection tests**

The setup preparation use case must:

1. reject an account label absent from trusted static config;
2. authorize without writing any runtime file;
3. identify the authenticated identity from the primary CalendarList entry;
4. require an explicit `yes` confirmation;
5. parse a comma-separated set of displayed calendar numbers;
6. generate a random bundle generation and return one complete `PreparedSetup{Bundle}` only after confirmation, leaving persistence and restart work to the app boundary.

Use an injected `Prompter`:

```go
type Prompter interface {
    ConfirmIdentity(identity, label string) (bool, error)
    SelectCalendars(calendars []storage.CalendarRef) ([]storage.CalendarRef, error)
}

type PreparedSetup struct {
    Bundle storage.AuthorizationBundle
}
```

- [ ] **Step 3: Run focused tests and confirm RED**

Run:

```sh
go test ./internal/googlecalendar -run 'TestClient|TestSetup|TestClassify'
```

Expected: FAIL because client/setup functions are absent.

- [ ] **Step 4: Implement CalendarList and Events adapters**

Use the official fluent calls exactly:

```go
resp, err := c.service.CalendarList.List().PageToken(pageToken).Context(ctx).Do()

resp, err := c.service.Events.List(calendarID).
    SingleEvents(true).
    OrderBy("startTime").
    TimeMin(start.Format(time.RFC3339)).
    TimeMax(end.Format(time.RFC3339)).
    MaxResults(250).
    PageToken(pageToken).
    Context(ctx).
    Do()
```

For `EventDateTime`, treat non-empty `Date` as all-day; otherwise parse `DateTime` as RFC3339. Copy `RecurringEventId`; when it is non-empty, require and parse `OriginalStartTime.DateTime` or `OriginalStartTime.Date` into `Candidate.OriginalStart`. Set `Declined` only when an attendee has `Self == true` and `ResponseStatus == "declined"`. Copy only video conference URIs into `ConferenceURLs`. Preserve the other normalized fields required by Task 2.

Classify errors using typed/stable fields only. `googleapi.Error.Code == 401` or reasons `authError`/`invalidCredentials` are auth; `429` and `403` reasons `rateLimitExceeded`, `userRateLimitExceeded`, or `quotaExceeded` are rate-limit; `500-599` and `net.Error` timeouts are transient; `errors.Is(err, context.Canceled)` is cancellation; all other API responses are permanent. Use `var retrieveErr *oauth2.RetrieveError; errors.As(err, &retrieveErr)` and compare `retrieveErr.ErrorCode == "invalid_grant"` for auth. Never match rendered error strings. Add table tests for every category, including a `403` permanent reason and a transport timeout.

- [ ] **Step 5: Implement setup orchestration and terminal prompts**

`Setup.Prepare` receives trusted config, label, credential bytes, `Authorizer`, client factory, `Prompter`, and an injected random reader; it does not receive storage. It returns `PreparedSetup.Bundle` with version `1`, a base64url-encoded 32-byte generation, defensive OAuth client bytes, the non-empty-refresh-token token, confirmed identity, and selected calendars. The primary calendar ID is the displayed authenticated identity; no additional identity scope is requested. Preparation failures leave existing bundles untouched.

The terminal prompter prints numbered calendar summaries, reads comma-separated 1-based indexes, rejects duplicates/out-of-range values, and requires at least one selected calendar.

- [ ] **Step 6: Run all Google adapter tests**

Run:

```sh
gofmt -w internal/googlecalendar
go test -race ./internal/googlecalendar
```

Expected: PASS with both pagination pages observed and no prepared setup returned on rejected identity.

- [ ] **Step 7: Commit Google synchronization**

```sh
git add modules/home/desktop/services/meeting-notifier/internal/googlecalendar
git commit -m "feat(calendar): sync Google meeting calendars"
```

---

### Task 6: Implement actionable freedesktop notifications

**Files:**
- Modify: `modules/home/desktop/services/meeting-notifier/go.mod`
- Modify: `modules/home/desktop/services/meeting-notifier/go.sum`
- Create: `modules/home/desktop/services/meeting-notifier/internal/notifications/client.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/notifications/client_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/notifications/signals.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/notifications/signals_test.go`

**Interfaces:**
- Produces: `notifications.Client.Run(ctx, commands, events)`, `notifications.Command`, `notifications.Event`, `notifications.Request`, and `notifications.Signal`.
- Consumes: freedesktop `org.freedesktop.Notifications` via godbus.

- [ ] **Step 1: Add the pinned DBus dependency**

Run:

```sh
cd modules/home/desktop/services/meeting-notifier
go get github.com/godbus/dbus/v5@v5.2.2
```

Expected: `go.mod` and `go.sum` pin godbus.

- [ ] **Step 2: Write failing protocol argument and signal tests**

Use these public types:

```go
type Request struct {
    ReplacesID uint32
    Summary    string
    Body       string
    Actions    []string
}

type SignalKind int

const (
    ActionInvoked SignalKind = iota + 1
    NotificationClosed
)

type Signal struct {
    Kind      SignalKind
    ID        uint32
    ActionKey string
    Reason    uint32
}

type CommandKind int

const (
    NotifyCommand CommandKind = iota + 1
    CloseCommand
)

type Command struct {
    Kind          CommandKind
    OccurrenceKey string
    Request       Request
    NotificationID uint32
}

type EventKind int

const (
    NotificationDelivered EventKind = iota + 1
    NotificationFailed
    SignalReceived
)

type DeliveryAck struct {
    Persisted bool
    Err       error
}

type Event struct {
    Kind           EventKind
    OccurrenceKey  string
    NotificationID uint32
    Signal         Signal
    Err            error
    DeliveryAck    chan DeliveryAck // dispatcher creates with capacity 1
}

type Transport interface {
    Run(context.Context, <-chan Command, chan<- Event) error
}
```

Tests must assert a meeting request passes exactly `[]string{"join", "Join"}`, an authentication warning passes a nil/empty action array, and the timeout is `int32(-1)`. Malformed signal bodies are logged and ignored rather than panicking. Prequeue an action signal while Notify completes and assert `NotificationDelivered` is delivered first with `cap(event.DeliveryAck) == 1`. Send `DeliveryAck{Persisted: true}` and only then expect `SignalReceived`. Cancel a second dispatcher while it awaits ack, assert it returns the context error, then send a late ack into the capacity-one channel and assert the send does not block. In a third test send `DeliveryAck{Persisted: false, Err: sentinel}`; assert the dispatcher calls `CloseNotification` once under its own deadline, forwards no queued action, and returns the persistence error joined with any close error. Block the consumer, verify the transport blocks without dropping the event, then cancel and verify `Run` exits with the context error. Decode these exact bodies:

```go
[]any{uint32(42), "join"}
[]any{uint32(42), uint32(2)}
```

- [ ] **Step 3: Run tests and confirm RED**

Run:

```sh
go test ./internal/notifications
```

Expected: FAIL because the package does not exist.

- [ ] **Step 4: Implement direct Notify, close, and signal subscription**

Call the freedesktop method with exact positional types:

```go
call := obj.CallWithContext(ctx, "org.freedesktop.Notifications.Notify", 0,
    "meeting-notifier",
    req.ReplacesID,
    "",
    req.Summary,
    req.Body,
    req.Actions,
    map[string]dbus.Variant{},
    int32(-1),
)
var id uint32
if err := call.Store(&id); err != nil {
    return 0, err
}
```

`Client.Run` subscribes before accepting commands and owns both DBus method calls and raw signal forwarding. Its single dispatcher selects commands and raw signals. The daemon provides an unbuffered `events` ingress. For Notify, the dispatcher performs the bounded DBus call, creates `ack := make(chan DeliveryAck, 1)`, sends `NotificationDelivered`, and waits with `select { case result := <-ack: case <-ctx.Done(): }` before selecting another command or raw signal. On a successful ack it resumes normally. On a failed ack it calls `CloseNotification` with a fresh `5s` compensation context, returns the joined persistence/close error, and never forwards queued actions for the uncommitted ID. Close commands use `CloseNotification` and the same ordered result path. Decoded valid signals use cancellable blocking delivery to the event loop—never a default/drop branch or restart-on-full error. A raw godbus channel of capacity `64` absorbs short scheduling gaps; sustained load backpressures the DBus reader until the always-draining owner catches up. Malformed/unknown signals are logged and ignored. Shutdown unregisters the raw channel and closes the bus connection after the dispatcher returns.

- [ ] **Step 5: Run notification tests**

Run:

```sh
gofmt -w internal/notifications
go test -race ./internal/notifications
```

Expected: PASS; no test requires a live notification server.

- [ ] **Step 6: Commit notification transport**

```sh
git add modules/home/desktop/services/meeting-notifier/go.mod \
  modules/home/desktop/services/meeting-notifier/go.sum \
  modules/home/desktop/services/meeting-notifier/internal/notifications
git commit -m "feat(calendar): add actionable meeting notifications"
```

---

### Task 7: Detect the active graphical session through logind

**Files:**
- Create: `modules/home/desktop/services/meeting-notifier/internal/activity/logind.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/activity/logind_test.go`

**Interfaces:**
- Produces: `activity.Reader.Current(context.Context) (activity.Result, error)`.
- Consumes: system-bus logind session properties and `XDG_SESSION_ID`.

- [ ] **Step 1: Write failing eligibility tests**

Use:

```go
type Result struct {
    Eligible bool
    Degraded bool
}
```

Cover `(active=true,idle=false) -> eligible`, active idle and inactive sessions -> ineligible, and every lookup/type error -> `Eligible=true, Degraded=true` plus a non-nil error. This enforces the approved fail-open policy while preserving diagnostics.

- [ ] **Step 2: Run tests and confirm RED**

Run:

```sh
go test ./internal/activity
```

Expected: FAIL because logind support does not exist.

- [ ] **Step 3: Implement logind DBus reads**

Connect to the system bus, call:

```text
org.freedesktop.login1.Manager.GetSession(XDG_SESSION_ID)
```

Then read:

```text
org.freedesktop.login1.Session.Active
org.freedesktop.login1.Session.IdleHint
```

Use checked bool assertions on both `dbus.Variant` values. Separate the DBus property retrieval from a pure `evaluate(active, idle bool, err error) Result` function so failure policy is deterministic in tests. Close the system-bus connection when the reader is closed.

- [ ] **Step 4: Run activity tests**

Run:

```sh
gofmt -w internal/activity
go test -race ./internal/activity
```

Expected: PASS.

- [ ] **Step 5: Commit activity gating**

```sh
git add modules/home/desktop/services/meeting-notifier/internal/activity
git commit -m "feat(calendar): gate notifications by session activity"
```

---

### Task 8: Extract one canonical Firefox/Niri launcher

**Files:**
- Create: `modules/home/desktop/wayland/niri/firefox-launcher/go.mod`
- Create: `modules/home/desktop/wayland/niri/firefox-launcher/package.nix`
- Create: `modules/home/desktop/wayland/niri/firefox-launcher/cmd/niri-firefox-launcher/main.go`
- Create: `modules/home/desktop/wayland/niri/firefox-launcher/internal/launcher/launcher.go`
- Create: `modules/home/desktop/wayland/niri/firefox-launcher/internal/launcher/launcher_test.go`
- Create: `modules/home/desktop/wayland/niri/firefox-launcher/internal/launcher/niri.go`
- Create: `modules/home/desktop/wayland/niri/firefox-launcher/internal/launcher/niri_test.go`
- Modify: `modules/home/desktop/wayland/niri/config/autostart.nix`
- Modify: `modules/home/desktop/wayland/niri/config/firefox-profiles.sh`
- Create: `modules/home/desktop/services/meeting-notifier/internal/launcher/client.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/launcher/client_test.go`

**Interfaces:**
- Produces: CLI commands `niri-firefox-launcher launch-profile`, `open-url`, and `focus-workspace`; meeting adapter `launcher.Client.Open(ctx, profile, rawURL) error`.
- Consumes: Niri JSON/actions, Firefox, Task 2 URL validation, and direct argv execution.

- [ ] **Step 1: Write failing shared placement and mode tests**

Initialize the stdlib-only shared module, then use the pinned Niri fixtures:

```sh
cd modules/home/desktop/wayland/niri/firefox-launcher
go mod init github.com/rochecompaan/nixdots/niri-firefox-launcher
```

```json
[
  {"id":3,"app_id":"firefox-profile-default","pid":128592,"workspace_id":2},
  {"id":50,"app_id":"firefox-profile-clubhouse","pid":200000,"workspace_id":6}
]
```

```json
[
  {"id":5,"idx":5,"name":"5","output":"HDMI-A-1","active_window_id":null}
]
```

Test both modes against the same `windowIDs`, `workspaceTarget`, `profileAppID`, and placement functions:

- `launch-profile --workspace 6 --profile clubhouse` snapshots IDs, starts Firefox with `--new-instance -P clubhouse`, preserves both app-ID environment variables, waits up to 15 seconds, retains the two-second restore settle, moves every new window, and never focuses it;
- `open-url --workspace 5 --profile clubhouse --url <URL>` sets `MOZ_APP_REMOTINGNAME=firefox-profile-clubhouse` and `MOZ_APP_LAUNCHER=firefox-profile-clubhouse`, starts Firefox with `-P clubhouse --new-window <URL>`, accepts only a new exact matching app-ID window, moves it, then focuses monitor/workspace/window;
- timeout leaves Firefox open and performs no relaunch;
- `focus-workspace --workspace 2` uses the same output/index resolution.

Assert the exact Niri action argv from the prior plan, including `--focus false`.

- [ ] **Step 2: Write failing meeting adapter and startup-dispatch tests**

The meeting adapter must revalidate the URL and execute exactly:

```text
<niriFirefoxLauncher> open-url --workspace 5 --profile clubhouse --url <validated URL>
```

Use an injected direct runner; an invalid URL must produce no process call. Test that the reduced `firefox-profiles.sh` contains only the one-second startup delay, sequential trusted `launch-profile` invocations for the existing profile/workspace pairs, and final `focus-workspace --workspace 2`. Do not test static script text; run it with a fake `niri-firefox-launcher` on `PATH` and assert captured argv order.

- [ ] **Step 3: Run launcher tests and confirm RED**

Run:

```sh
cd modules/home/desktop/wayland/niri/firefox-launcher
go test ./...
cd ../../../services/meeting-notifier
go test ./internal/launcher
```

Expected: FAIL because shared launcher and meeting adapter types do not exist.

- [ ] **Step 4: Implement and package the canonical launcher**

Define only used Niri JSON fields and strict decoding. One launcher implementation owns profile app IDs, both Firefox app-ID environment variables for both modes, snapshots, workspace output/index fallback, polling, and move/focus actions. The CLI parses with `flag.FlagSet`, rejects missing/unknown arguments, and reads trusted `FIREFOX_BIN`/`NIRI_BIN` set by its Nix wrapper. `open-url` treats the URL as opaque argv and never invokes a shell.

`package.nix` uses `buildGoModule` with `vendorHash = null` and `makeWrapper` to set absolute Firefox and Niri binaries. Replace placement logic in `firefox-profiles.sh` with the thin trusted dispatcher described in Step 2, and make `autostart.nix` include the shared package as its only runtime input. Preserve existing profile order, workspace assignments, `--new-instance`, settle timing, and final workspace focus.

- [ ] **Step 5: Implement the meeting adapter and run race tests**

`launcher.Client` receives `config.FirefoxLauncherBin`, workspace, allowed hosts, and a direct runner. It calls `meeting.ValidateURL` immediately before direct execution and never parses Niri JSON itself.

Run:

```sh
cd modules/home/desktop/wayland/niri/firefox-launcher
gofmt -w cmd internal
go test -race ./...
cd ../../../services/meeting-notifier
gofmt -w internal/launcher
go test -race ./internal/launcher
```

Expected: PASS for startup and meeting modes from the shared implementation.

- [ ] **Step 6: Commit canonical launcher integration**

```sh
git add modules/home/desktop/wayland/niri/firefox-launcher \
  modules/home/desktop/wayland/niri/config/autostart.nix \
  modules/home/desktop/wayland/niri/config/firefox-profiles.sh \
  modules/home/desktop/services/meeting-notifier/internal/launcher
git commit -m "refactor(niri): share Firefox window launcher"
```

---

### Task 9: Build the one-owner reducer, workers, status, and CLI

**Files:**
- Create: `modules/home/desktop/services/meeting-notifier/internal/daemon/retry.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/daemon/retry_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/daemon/reducer.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/daemon/reducer_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/daemon/daemon.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/daemon/daemon_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/status/status.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/status/status_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/app/app.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/app/app_test.go`
- Create: `modules/home/desktop/services/meeting-notifier/cmd/meeting-notifier/main.go`

**Interfaces:**
- Produces: the complete `setup`, `run`, and `status` behavior; `daemon.Reduce(state, event) (state, effects, error)`.
- Consumes: every interface from Tasks 1-8.

- [ ] **Step 1: Write failing retry and event-contract tests**

Keep per-account retry attempts and `NextAttempt`; test delays `1m`, `2m`, `4m`, `8m`, capped at `15m`, with injected jitter in `[0, delay/4]`. Define immutable worker events:

```go
type PollResult struct {
    AccountLabel string
    FetchedAt    time.Time
    Meetings     []meeting.Meeting
    Err          error
}

type ActivityResult struct {
    CheckedAt time.Time
    Result    activity.Result
    Err       error
}

type LaunchResult struct {
    OccurrenceKey string
    Err           error
}

type EventKind int

const (
    TickEvent EventKind = iota + 1
    PollResultEvent
    ActivityResultEvent
    NotificationEvent
    LaunchResultEvent
)

type Event struct {
    Kind         EventKind
    At           time.Time
    Poll         *PollResult
    Activity     *ActivityResult
    Notification *notifications.Event
    Launch       *LaunchResult
}
```

Workers receive copies and have no `StateStore` reference.

- [ ] **Step 2: Write failing reducer lifecycle tests**

Define only owner-facing boundaries:

```go
type Source interface {
    SyncAccount(context.Context, string, storage.AuthorizationBundle, time.Time, time.Time) ([]meeting.Meeting, error)
}

type StateStore interface {
    LoadState() (storage.State, error)
    SaveState(storage.State) error
}

type Activity interface {
    Current(context.Context) (activity.Result, error)
}

type Launcher interface {
    Open(context.Context, string, string) error
}
```

Table-test every legal transition and reject every illegal phase/field combination. Required cases:

- a tick with due scheduled occurrences emits one activity-check effect without changing phase; an eligible or degraded-fail-open `ActivityResult` performs `scheduled -> notify-pending`, while an idle/inactive result leaves it scheduled;
- persistence of `notify-pending` before a Notify effect;
- delivery result before immediate `ActionInvoked`, followed by `notified -> join-pending`;
- unknown ID, wrong action, invalid URL, expired action, or `close-pending` never launches;
- expiry/dismissal/undefined `NotificationClosed` yields `actionable-history` and retains Join until action expiry;
- daemon-requested close invalidates Join first and completes only after close result/signal;
- launch success transitions to terminal `joined`, clears actionability, and retains the aggregate until event/action expiry; launch failure returns through `ResumePhase` to `notified`/`actionable-history` for retry;
- cancellation, deletion, decline, URL removal, and rescheduling produce reason-specific close transitions;
- rescheduling within the lead window replaces using the prior ID; outside it closes then resumes `scheduled`;
- ambiguous Notify failure retains `notify-pending` with bounded `NotBefore` and the documented at-least-once duplicate risk;
- authentication warnings are actionless and rate-limited per account;
- `joined` and expired history aggregates remain deduplication tombstones until event/action expiry, then prune.

- [ ] **Step 3: Write failing one-owner and backlog tests**

Use a spy `StateStore` that records concurrent calls and ordered snapshots. Feed poll, notification signal, and launcher completion events concurrently. Assert:

1. `LoadState` runs once and `SaveState` never overlaps another state operation.
2. Every event is reduced serially with no lost lifecycle or snapshot update.
3. State validates and saves before each derived effect is dispatched.
4. Notification delivery is persisted and positively acknowledged before the queued action signal is reduced.
5. Injecting `SaveState` failure for `NotificationDelivered` sends a negative delivery ack, performs exactly one compensating close, performs no second state write, forwards no action, and returns the joined error. Other save failures dispatch no effect.
6. Startup with 100 `join-pending` aggregates starts one launcher command, then one more after each result; there is no replay queue or overflow restart.
7. A blocked event consumer backpressures notification, activity, and poll workers until cancellation without dropping an event.
8. Failed account polls retain snapshots and produce no reconciliation transition.

The owner keeps `activityBusy`, `notifierBusy`, and `launcherBusy` booleans. Durable aggregate phases are the work queues. Each worker has one capacity-one immutable command slot; the owner sends only while its busy flag is false, and after each result scans durable state for the next oldest pending aggregate.

- [ ] **Step 4: Write executable status redaction tests**

Seed bundles and state with concrete sentinels and assert exact absence:

```go
meetingURL := strings.Join([]string{
    "https://acme.zoom.us/j/9135550199",
    "source=sentinel",
}, "?")
secrets := []string{
    "sentinel-access-token-7b2f",
    "sentinel-refresh-token-91cd",
    meetingURL,
    "sentinel confidential event description",
}
for _, secret := range secrets {
    if strings.Contains(got, secret) {
        t.Fatalf("status leaked %q", secret)
    }
}
```

Status may include labels, calendar summaries, last success, cache age, next title/time, lifecycle phase, and stable error categories. It never prints bundle/token bodies, descriptions, authorization codes, or complete URLs.

- [ ] **Step 5: Run orchestration tests and confirm RED**

Run:

```sh
go test ./internal/daemon ./internal/status ./internal/app
```

Expected: FAIL because reducer, owner loop, and app wiring do not exist.

- [ ] **Step 6: Implement the reducer and one state-owning loop**

`Reduce` is deterministic: it copies/mutates only the owner's state, validates lifecycle invariants, and returns effects without executing them. The event loop loads state once, rebuilds `NotificationIndex`, owns one unbuffered event ingress, and is the only caller of `SaveState`. For every event it applies Reduce, validates, saves if changed, publishes the new in-memory state/index, and then dispatches effects. Ordinary save failure is fatal before any new effect. The sole exception is `NotificationDelivered`: the external Notify already happened, so a save failure sends `DeliveryAck{Persisted:false, Err:saveErr}` with a non-blocking send into the required capacity-one channel, waits for its bounded compensating close/return, performs no additional state write, and exits with joined errors. Successful persistence publishes the new state/index and sends a positive ack through the same non-blocking helper; a full channel is an invariant error, never a blocking send. If the dispatcher already exited on cancellation, the late ack remains buffered and shutdown still completes.

Polling workers run with per-account `30s` deadlines and return copied `PollResult` values through cancellable blocking sends. A single activity worker calls `Activity.Current` under a `5s` deadline and returns `ActivityResult`; reducer policy preserves the approved degraded fail-open behavior. The notification dispatcher from Task 6 emits ordered delivery/signal events the same way. One launcher worker runs with a `20s` deadline. None reads or writes state.

On startup, ticks, and after every result, the owner scans lifecycle aggregates. If due scheduled work exists and the activity worker is idle, it places one activity command in that worker's capacity-one slot. For persisted `notify-pending`, `close-pending`, or `join-pending` work, it places one oldest effect in the corresponding empty capacity-one slot and sets the in-memory busy flag. Remaining work stays durable; the slot can never overflow under the busy invariant. This removes replay queues and restart-based backpressure.

- [ ] **Step 7: Implement bundle-aware setup, status, and CLI wiring**

Use:

```text
meeting-notifier setup --credentials /path/to/credentials.json <account-label>
meeting-notifier run
meeting-notifier status
```

`setup` calls `Setup.Prepare`, then `Store.SaveAuthorization(label, prepared.Bundle)`. Only after the atomic writer reports success does `ServiceManager.Restart(context.Context)` execute trusted `SystemctlBin --user restart meeting-notifier.service`. A pre-rename failure preserves the old bundle; a reported post-rename failure may leave the new complete bundle visible and returns rerun/restart guidance without claiming rollback. Restart failure returns contextual error while leaving a complete bundle. App tests verify no restart on preparation/write failure, restart after durability, cross-label isolation, and stale-generation refresh rejection.

`run` strictly decodes each configured label's bundle, constructs clients with that bundle's own OAuth client/token/generation, and translates a missing, malformed, unsupported-version, or auth-required bundle into an explicit unavailable result for only that account. It then loads daemon state once and starts the reducer plus available-account workers. `status` reports those categories and returns non-zero while any label is unavailable.

`main.go` contains only signal-context creation, `app.Run`, redacted error output, and exit status.

- [ ] **Step 8: Run the full Go test suite and vet**

Run:

```sh
cd modules/home/desktop/services/meeting-notifier
gofmt -w cmd internal
go test -race ./...
go vet ./...
```

Expected: all tests PASS; the state-store spy reports maximum concurrency `1`.

- [ ] **Step 9: Commit daemon orchestration**

```sh
git add modules/home/desktop/services/meeting-notifier/cmd \
  modules/home/desktop/services/meeting-notifier/internal/app \
  modules/home/desktop/services/meeting-notifier/internal/daemon \
  modules/home/desktop/services/meeting-notifier/internal/status
git commit -m "feat(calendar): run serialized meeting notifier"
```

---

### Task 10: Package with Nix, enable both hosts, document setup, and verify

**Files:**
- Create: `modules/home/desktop/services/meeting-notifier/package.nix`
- Create: `modules/home/desktop/services/meeting-notifier/default.nix`
- Create: `modules/home/desktop/services/meeting-notifier/README.md`
- Modify: `modules/home/desktop/services/default.nix:2-13`
- Modify: `home/roche/kiptum.nix:14-19`
- Modify: `home/roche/kipchoge.nix:18-22`

**Interfaces:**
- Produces: `services.meetingNotifier` Home Manager options, installed package/config, `meeting-notifier.service`, and both host mappings.
- Consumes: the meeting notifier and shared Firefox launcher from Tasks 1-9.

- [ ] **Step 1: Create the buildGoModule derivation with the fake-hash cycle**

Create `package.nix`:

```nix
{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "meeting-notifier";
  version = "0.1.0";

  src = lib.cleanSource ./.;
  vendorHash = lib.fakeHash;

  subPackages = [ "cmd/meeting-notifier" ];

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Actionable Google Calendar meeting notifications for Niri";
    homepage = "https://github.com/rochecompaan/nixdots";
    license = lib.licenses.mit;
    mainProgram = "meeting-notifier";
    platforms = lib.platforms.linux;
  };
}
```

Run the package build through an impure path flake or direct callPackage expression, copy the reported `got: sha256-...` value into `vendorHash`, and rerun until it succeeds. Do not leave `lib.fakeHash` in the committed derivation.

- [ ] **Step 2: Create the Home Manager module**

Create `default.nix` with options:

```nix
services.meetingNotifier = {
  enable = lib.mkEnableOption "actionable Google Calendar meeting notifications";
  package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.callPackage ./package.nix { };
    description = "Meeting notifier package.";
  };
  pollInterval = lib.mkOption {
    type = lib.types.str;
    default = "1m";
  };
  leadTime = lib.mkOption {
    type = lib.types.str;
    default = "5m";
  };
  horizon = lib.mkOption {
    type = lib.types.str;
    default = "24h";
  };
  workspace = lib.mkOption {
    type = lib.types.str;
    default = "5";
  };
  allowedHosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "meet.google.com"
      "zoom.us"
      "*.zoom.us"
    ];
  };
  accounts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options.firefoxProfile = lib.mkOption {
        type = lib.types.str;
        description = "Existing Firefox profile used for this account label.";
      };
    });
    default = { };
  };
};
```

Bind `jsonFormat = pkgs.formats.json { };` and `configFile = jsonFormat.generate "meeting-notifier-config.json" { ... };`. The generated JSON contains the exact camelCase fields from Task 1 and these absolute binaries:

```nix
browserBin = lib.getExe' pkgs.xdg-utils "xdg-open";
firefoxLauncherBin = lib.getExe firefoxLauncher;
systemctlBin = lib.getExe' pkgs.systemd "systemctl";
```

Define `firefoxLauncher = pkgs.callPackage ../../wayland/niri/firefox-launcher/package.nix { firefox = config.programs.firefox.package; niri = pkgs.niri; };`. Install the JSON as `xdg.configFile."meeting-notifier/config.json".source = configFile`. Add `cfg.package` to `home.packages`; the launcher remains an absolute runtime dependency through `firefoxLauncherBin`.

The service must be:

```nix
systemd.user.services.meeting-notifier = {
  Unit = {
    Description = "Google Calendar meeting notifier";
    PartOf = [ "graphical-session.target" ];
    After = [ "graphical-session.target" ];
    X-Restart-Triggers = [ "${configFile}" ];
  };
  Service = {
    Type = "simple";
    ExecStart = "${lib.getExe cfg.package} run";
    Restart = "on-failure";
    RestartSec = 5;
  };
  Install.WantedBy = [ "graphical-session.target" ];
};
```

Guard configuration with `config.default.isDesktop && cfg.enable`. Define `validDuration = value: builtins.match "^[1-9][0-9]*(s|m|h)$" value != null;` and `validHost = value: builtins.match "^([*][.])?[A-Za-z0-9][A-Za-z0-9.-]*$" value != null;`. Add assertions that `config.default.de == "niri"`, `cfg.accounts != { }`, every `firefoxProfile` is non-empty, all three duration options satisfy `validDuration`, and every allowed host satisfies `validHost`.

- [ ] **Step 3: Import and enable the module on both hosts**

Add `./meeting-notifier` alphabetically to `modules/home/desktop/services/default.nix`.

Add this exact block to both `home/roche/kiptum.nix` and `home/roche/kipchoge.nix`:

```nix
services.meetingNotifier = {
  enable = true;
  accounts = {
    alpha.firefoxProfile = "clubhouse";
    sixfeetup.firefoxProfile = "sixfeetup";
    upfront.firefoxProfile = "default";
  };
};
```

No account email or calendar ID belongs in either file.

- [ ] **Step 4: Write operator documentation**

Create `README.md` with exact instructions for:

1. Creating a Google Desktop OAuth client with Calendar API enabled and the three accounts allowed by the OAuth consent configuration.
2. Copying the downloaded credential JSON to a temporary private path.
3. Running, on each host:

```sh
meeting-notifier setup --credentials /private/path/credentials.json upfront
meeting-notifier setup --credentials /private/path/credentials.json sixfeetup
meeting-notifier setup --credentials /private/path/credentials.json alpha
meeting-notifier status
systemctl --user status meeting-notifier.service
journalctl --user -u meeting-notifier.service
```

4. Selecting only intended calendars during each setup.
5. The setup lifecycle: each label is one complete versioned bundle; setup atomically replaces only that bundle and then restarts the service after reported write success. Pre-rename failure preserves the old bundle; post-rename sync/close failure is durability-ambiguous but leaves only old-or-new complete content. Any write/restart error reports rerun/restart guidance.
6. Reauthorizing by rerunning setup with forced consent and confirming `meeting-notifier status` after the automatic restart.
7. Rollback with `services.meetingNotifier.enable = false` while preserving XDG data/state.
8. Explicit credential removal below `$XDG_DATA_HOME/meeting-notifier` only after stopping the service.
9. The approved live smoke test, including active-host, profile mapping, workspace `5`, cancellation, deletion, decline, URL removal, rescheduling, URL update, and cached-network-interruption cases.

Documentation is verified by command accuracy and review; do not add tests that assert prose.

- [ ] **Step 5: Stage new files before git-backed flake builds**

New Nix/Go files are otherwise excluded from normal git-backed flake evaluation. Run:

```sh
git add modules/home/desktop/services/meeting-notifier \
  modules/home/desktop/services/default.nix \
  modules/home/desktop/wayland/niri/firefox-launcher \
  modules/home/desktop/wayland/niri/config/autostart.nix \
  modules/home/desktop/wayland/niri/config/firefox-profiles.sh \
  home/roche/kiptum.nix \
  home/roche/kipchoge.nix
```

Do not commit yet.

- [ ] **Step 6: Run focused Go and Nix verification**

Run:

```sh
cd modules/home/desktop/wayland/niri/firefox-launcher
go test -race ./...
go vet ./...
cd ../../../services/meeting-notifier
go test -race ./...
go vet ./...
cd ../../../../..
bash -n modules/home/desktop/wayland/niri/config/firefox-profiles.sh
nix fmt -- --check \
  modules/home/desktop/services/meeting-notifier/package.nix \
  modules/home/desktop/services/meeting-notifier/default.nix \
  modules/home/desktop/services/default.nix \
  modules/home/desktop/wayland/niri/firefox-launcher/package.nix \
  modules/home/desktop/wayland/niri/config/autostart.nix \
  home/roche/kiptum.nix \
  home/roche/kipchoge.nix
statix check \
  modules/home/desktop/services/meeting-notifier/package.nix \
  modules/home/desktop/services/meeting-notifier/default.nix \
  modules/home/desktop/services/default.nix \
  modules/home/desktop/wayland/niri/firefox-launcher/package.nix \
  modules/home/desktop/wayland/niri/config/autostart.nix \
  home/roche/kiptum.nix \
  home/roche/kipchoge.nix
nix build .#homeConfigurations."roche@kiptum".activationPackage
nix build .#homeConfigurations."roche@kipchoge".activationPackage
```

Expected: all commands exit `0`; both activation packages include the generated config, `meeting-notifier.service`, and the shared launcher closure.

- [ ] **Step 7: Run full repository verification**

Run:

```sh
nix flake check --accept-flake-config --print-build-logs
```

Expected: exit `0`. No Pi dependency changed, so the Pi-specific extension-load check is not required.

- [ ] **Step 8: Review staged scope and commit integration**

Run:

```sh
git diff --cached --check
git diff --cached --stat
git status --short
```

Expected: only meeting-notifier source/module/docs, shared launcher extraction, Niri autostart integration, the services import, and the two Home Manager profiles are staged.

Commit:

```sh
git commit -m "feat(home): add Google meeting notifier"
```

- [ ] **Step 9: Perform live smoke testing after activation**

Activate one host first, authorize all labels, and execute the smoke test from the design. Record runtime-only results separately from committed source. Then activate and authorize the second host. Do not claim active-host, real Noctalia action, OAuth, Firefox profile routing, or workspace placement is verified until these live checks are completed.

## Plan Self-Review Checklist

- Spec coverage: every goal, non-goal, security boundary, Join sequence, failure mode, test requirement, and rollback rule maps to Tasks 1-10.
- Type consistency: `meeting.Meeting`, `storage.State`, notification IDs, account labels, and URL strings use the same names and types across tasks.
- Security consistency: OAuth scope, private modes, direct argv execution, URL revalidation, redacted status, and no repository account identities remain explicit.
- Testing Value Gate: reusable Go behavior has automated tests; Nix static values and README prose use direct verification.
- The shared-launcher extraction preserves existing Firefox startup order, modes, workspace assignments, settle timing, and focus while removing duplicated placement logic.
- Live-only claims remain clearly separated from automated verification.
