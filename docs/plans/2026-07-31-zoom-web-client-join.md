# Zoom Web Client Join Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make meeting-notifier open standard Zoom `/j/<numeric-id>` links directly in Zoom's browser client while retaining the existing behavior for every other meeting URL.

**Architecture:** Keep the Calendar-derived URL unchanged in durable state. Add a pure Zoom-specific launch URL transformer in the meeting domain, call it only after the launcher's existing action-time URL validation, validate its output again, and pass the result as one opaque argv value to the canonical Firefox/Niri launcher.

**Tech Stack:** Go 1.26.3 standard library (`net/url`, `regexp`, `strings`), existing meeting-notifier launcher client, Go testing/race detector/vet, Nix, Home Manager.

## Global Constraints

- Follow strict red-green-refactor TDD: every production behavior change starts with a failing behavior test whose failure is observed.
- Rewrite only hosts whose normalized hostname is exactly `zoom.us` or ends with `.zoom.us` on a label boundary.
- Rewrite only paths exactly matching `/j/<meeting-id>`, where the meeting ID contains ASCII decimal digits only and no trailing segment.
- Preserve the original host and the first decoded `pwd` value when present.
- Set `ref_from=launch` and `fromPWA=1`; discard all other source query parameters and fragments.
- Leave Google Meet and every nonmatching but valid Zoom URL unchanged.
- Preserve the existing HTTPS allowlist, user-info rejection, and action-time revalidation boundaries.
- Never pass event text or URLs through a shell; the final URL remains one direct argv value.
- Do not change Calendar normalization, durable state schemas, configuration, account mappings, or the Firefox/Niri launcher protocol.
- Keep provider-specific transformation separate from generic URL extraction and validation; target production modules remain under approximately 200 meaningful lines.
- One initial pre-plan race baseline failed in the unrelated OAuth test `TestAuthorizerRejectsTokenWithoutRefreshTokenBeforeSuccess`; the focused test then passed 10 consecutive runs and the complete race suite passed. If it recurs, record and investigate it separately rather than modifying OAuth code in this task.

---

### Task 1: Implement the pure Zoom web-client URL transformer

**Files:**
- Create: `modules/home/desktop/services/meeting-notifier/internal/meeting/zoom.go`
- Create: `modules/home/desktop/services/meeting-notifier/internal/meeting/zoom_test.go`

**Interfaces:**
- Consumes: a URL that the caller has already validated with `meeting.ValidateURL`.
- Produces: `func ZoomWebClientURL(rawURL string) (string, error)`, returning the transformed launch URL or the original URL when it does not structurally match a standard Zoom join link.

- [ ] **Step 1: Write the failing transformation tests**

Create `modules/home/desktop/services/meeting-notifier/internal/meeting/zoom_test.go`:

```go
package meeting

import "testing"

func TestZoomWebClientURLRewritesStandardJoinLinks(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "apex host without password",
			input: "https://zoom.us/j/123456789?tracking=drop#fragment",
			want:  "https://zoom.us/wc/123456789/start?fromPWA=1&ref_from=launch",
		},
		{
			name:  "subdomain with encoded password",
			input: "https://sixfeetup.zoom.us/j/87625926941?pwd=a%2Bb%2Fc%3D&tracking=drop#fragment",
			want:  "https://sixfeetup.zoom.us/wc/87625926941/start?fromPWA=1&pwd=a%2Bb%2Fc%3D&ref_from=launch",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ZoomWebClientURL(test.input)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("ZoomWebClientURL(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

func TestZoomWebClientURLLeavesNonmatchingURLsUnchanged(t *testing.T) {
	inputs := []string{
		"https://meet.google.com/abc-defg-hij",
		"https://zoom.us/my/personal-room",
		"https://zoom.us/wc/123456789/start?fromPWA=1",
		"https://zoom.us/meeting/register/example",
		"https://zoom.us/j/not-numeric",
		"https://zoom.us/j/123456789/",
		"https://zoom.us/j/123%2F456",
		"https://zoom.us.evil.example/j/123456789",
		"https://evilzoom.us/j/123456789",
	}

	for _, input := range inputs {
		got, err := ZoomWebClientURL(input)
		if err != nil {
			t.Fatalf("ZoomWebClientURL(%q): %v", input, err)
		}
		if got != input {
			t.Fatalf("ZoomWebClientURL(%q) = %q, want unchanged", input, got)
		}
	}
}

func TestZoomWebClientURLRejectsMalformedMatchingQuery(t *testing.T) {
	if _, err := ZoomWebClientURL("https://zoom.us/j/123456789?pwd=%zz"); err == nil {
		t.Fatal("expected malformed query error")
	}
}
```

- [ ] **Step 2: Run the focused test and observe the RED failure**

Run:

```sh
cd modules/home/desktop/services/meeting-notifier
go test ./internal/meeting -run '^TestZoomWebClientURL' -count=1
```

Expected: FAIL to compile with `undefined: ZoomWebClientURL`. If it fails for another reason, correct the test and rerun until the missing behavior is the only failure.

- [ ] **Step 3: Implement the minimal pure transformer**

Create `modules/home/desktop/services/meeting-notifier/internal/meeting/zoom.go`:

```go
package meeting

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

var zoomJoinPath = regexp.MustCompile(`^/j/([0-9]+)$`)

func ZoomWebClientURL(rawURL string) (string, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("parse Zoom meeting URL: %w", err)
	}

	host := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	if host != "zoom.us" && !strings.HasSuffix(host, ".zoom.us") {
		return rawURL, nil
	}

	match := zoomJoinPath.FindStringSubmatch(parsed.EscapedPath())
	if match == nil {
		return rawURL, nil
	}

	sourceQuery, err := url.ParseQuery(parsed.RawQuery)
	if err != nil {
		return "", fmt.Errorf("parse Zoom meeting query: %w", err)
	}
	targetQuery := url.Values{
		"fromPWA":  {"1"},
		"ref_from": {"launch"},
	}
	if passwords, ok := sourceQuery["pwd"]; ok && len(passwords) > 0 {
		targetQuery.Set("pwd", passwords[0])
	}

	target := &url.URL{
		Scheme:   parsed.Scheme,
		Host:     parsed.Host,
		Path:     "/wc/" + match[1] + "/start",
		RawQuery: targetQuery.Encode(),
	}
	return target.String(), nil
}
```

- [ ] **Step 4: Format the new files**

Run:

```sh
gofmt -w internal/meeting/zoom.go internal/meeting/zoom_test.go
```

Expected: command exits 0 and `gofmt -l internal/meeting/zoom.go internal/meeting/zoom_test.go` prints nothing.

- [ ] **Step 5: Run the focused tests and observe GREEN**

Run:

```sh
go test ./internal/meeting -run '^TestZoomWebClientURL' -count=1
```

Expected: PASS for all three `TestZoomWebClientURL...` tests.

- [ ] **Step 6: Run the complete meeting-domain race tests**

Run:

```sh
go test -race ./internal/meeting -count=1
```

Expected: PASS with no race reports.

- [ ] **Step 7: Commit the pure transformation**

Run from the repository worktree root:

```sh
git add \
  modules/home/desktop/services/meeting-notifier/internal/meeting/zoom.go \
  modules/home/desktop/services/meeting-notifier/internal/meeting/zoom_test.go
git diff --cached --check
git commit -S -m "feat(calendar): generate Zoom web-client URLs"
git verify-commit HEAD
```

Expected: the signed commit succeeds and its signature verifies.

---

### Task 2: Apply the transformation at Join time

**Files:**
- Modify: `modules/home/desktop/services/meeting-notifier/internal/launcher/client.go` (`Client.Open`)
- Modify: `modules/home/desktop/services/meeting-notifier/internal/launcher/client_test.go`
- Modify: `modules/home/desktop/services/meeting-notifier/README.md`

**Interfaces:**
- Consumes: `meeting.ZoomWebClientURL(rawURL string) (string, error)` from Task 1.
- Produces: `Client.Open` behavior that validates the source URL, transforms matching Zoom links, validates the launch URL, and sends it to `niri-firefox-launcher` as one argv value.

- [ ] **Step 1: Write the failing launcher integration test**

Append this test to `modules/home/desktop/services/meeting-notifier/internal/launcher/client_test.go`:

```go
func TestClientOpenRewritesZoomJoinURLForWebClient(t *testing.T) {
	runner := &fakeRunner{}
	client := NewClient(config.Config{
		FirefoxLauncherBin: "/nix/store/niri-firefox-launcher",
		Workspace:          "5",
		AllowedHosts:       []string{"zoom.us", "*.zoom.us"},
	}, runner)
	rawURL := "https://sixfeetup.zoom.us/j/87625926941?pwd=a%2Bb%2Fc%3D&tracking=drop#fragment"

	if err := client.Open(context.Background(), "sixfeetup", rawURL); err != nil {
		t.Fatal(err)
	}
	want := []runnerCall{{
		name: "/nix/store/niri-firefox-launcher",
		args: []string{
			"open-url",
			"--workspace", "5",
			"--profile", "sixfeetup",
			"--url", "https://sixfeetup.zoom.us/wc/87625926941/start?fromPWA=1&pwd=a%2Bb%2Fc%3D&ref_from=launch",
		},
	}}
	if !reflect.DeepEqual(runner.calls, want) {
		t.Fatalf("calls = %#v, want %#v", runner.calls, want)
	}
}
```

- [ ] **Step 2: Run the focused launcher test and observe the RED failure**

Run:

```sh
cd modules/home/desktop/services/meeting-notifier
go test ./internal/launcher -run '^TestClientOpenRewritesZoomJoinURLForWebClient$' -count=1
```

Expected: FAIL because the current launcher passes the original `/j/...` URL rather than the `/wc/.../start` URL. Confirm the recorded argv mismatch contains the original URL.

- [ ] **Step 3: Integrate transformation and second validation in `Client.Open`**

Replace `Client.Open` in `modules/home/desktop/services/meeting-notifier/internal/launcher/client.go` with:

```go
func (c Client) Open(ctx context.Context, profile, rawURL string) error {
	args := []string{"open-url", "--workspace", c.workspace, "--profile", profile, "--url"}
	validatedURL, err := meeting.ValidateURL(rawURL, c.allowedHosts)
	if err != nil {
		return fmt.Errorf("validate meeting URL: %w", err)
	}
	launchURL, err := meeting.ZoomWebClientURL(validatedURL)
	if err != nil {
		return fmt.Errorf("prepare meeting launch URL: %w", err)
	}
	launchURL, err = meeting.ValidateURL(launchURL, c.allowedHosts)
	if err != nil {
		return fmt.Errorf("validate meeting launch URL: %w", err)
	}
	if err := c.runner.Run(ctx, c.launcherBin, append(args, launchURL)...); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return classifyLauncherError(err)
	}
	return nil
}
```

- [ ] **Step 4: Format and run the launcher package tests**

Run:

```sh
gofmt -w internal/launcher/client.go internal/launcher/client_test.go
go test -race ./internal/launcher -count=1
```

Expected: PASS, including the new transformed argv test and the existing invalid-host/direct-argv tests.

- [ ] **Step 5: Document Zoom browser launch behavior**

Insert this section after the introductory paragraph in `modules/home/desktop/services/meeting-notifier/README.md`:

```markdown
## Zoom web-client joins

When **Join** receives a standard `https://<zoom-host>/j/<numeric-id>` URL,
meeting-notifier opens `https://<zoom-host>/wc/<numeric-id>/start` directly in
the configured Firefox profile. It preserves the Zoom `pwd` value and sets the
browser-client launch parameters. Other validated Zoom URL shapes and Google
Meet URLs open unchanged.
```

No automated test is added for this documentation-only text; verify it with `git diff --check` and review the rendered Markdown structure.

- [ ] **Step 6: Run complete Go verification**

Run:

```sh
cd modules/home/desktop/services/meeting-notifier
test -z "$(gofmt -l .)"
go test -race ./... -count=1
go vet ./...
```

Expected: all packages PASS, no race reports, no vet findings, and no files listed by `gofmt`.

If the previously observed OAuth callback timeout recurs, rerun only the named OAuth test with `-race -count=10`, record both results, and investigate it separately. Do not alter OAuth code as part of this Zoom task.

- [ ] **Step 7: Commit the Join-time integration and operator documentation**

Run from the repository worktree root:

```sh
git add \
  modules/home/desktop/services/meeting-notifier/internal/launcher/client.go \
  modules/home/desktop/services/meeting-notifier/internal/launcher/client_test.go \
  modules/home/desktop/services/meeting-notifier/README.md
git diff --cached --check
git commit -S -m "feat(calendar): open Zoom meetings in web client"
git verify-commit HEAD
```

Expected: the signed commit succeeds and its signature verifies.

---

### Task 3: Verify the complete branch in Nix and Home Manager

**Files:**
- Verify only; no source changes are expected.

**Interfaces:**
- Consumes: the committed implementation from Tasks 1 and 2.
- Produces: build, integration, signature, and cleanliness evidence for branch review.

- [ ] **Step 1: Build the meeting-notifier package directly**

Run from the repository worktree root:

```sh
nix build --no-link --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
  in
  pkgs.callPackage ./modules/home/desktop/services/meeting-notifier/package.nix { }
'
```

Expected: exit 0. This exact expression was validated against the pre-implementation worktree.

- [ ] **Step 2: Build both affected Home Manager activation packages**

Run:

```sh
nix build --no-link '.#homeConfigurations."roche@kiptum".activationPackage'
nix build --no-link '.#homeConfigurations."roche@kipchoge".activationPackage'
```

Expected: both commands exit 0.

- [ ] **Step 3: Run the full flake check**

Run:

```sh
nix flake check --accept-flake-config --print-build-logs
```

Expected: exit 0 and `all checks passed!`.

- [ ] **Step 4: Verify branch scope, signatures, and cleanliness**

Run:

```sh
git diff --check main...HEAD
git diff --stat main...HEAD
git log main..HEAD --format=%H | while read -r commit; do
  git verify-commit "$commit"
done
test -z "$(git status --porcelain)"
```

Expected: no whitespace errors, only the design/plan plus Zoom transformation/launcher/docs files in the branch diff, every branch commit has a good signature, and the worktree is clean.

## Operator-only validation after activation

After integrating and activating the change on the first host:

1. Create a near-term event containing a password-bearing `https://<zoom-host>/j/<numeric-id>?pwd=...` link.
2. Wait for the notification and invoke **Join**.
3. Confirm Firefox uses the configured account profile and Niri workspace `5`.
4. Confirm the loaded address uses `/wc/<numeric-id>/start` and does not show Zoom's app-versus-browser chooser.
5. Confirm the password-bearing meeting joins without an extra password prompt.
6. Confirm a Google Meet event still opens unchanged.

Repeat the profile-routing smoke check on the second host. These checks require live Zoom, Firefox, Niri, Noctalia, and user-systemd behavior and are not implied by automated verification.
