# Meeting Notifier Design

## Problem

The Niri desktops should notify the user five minutes before a Google Calendar event that contains a Google Meet or Zoom join link. Calendars span three Google accounts, and each account must open meetings in its corresponding Firefox profile. Selecting **Join** must open a new Firefox window, move it to named Niri workspace `5`, and focus it.

No calendar data is currently synchronized locally. Existing tools cover parts of the workflow, but none provides the complete combination of multi-account Google synchronization, structured conference-link handling, actionable Noctalia notifications, Firefox profile routing, active-host suppression, and Niri placement.

## Goals

- Authorize and poll multiple Google accounts independently.
- Use an explicit calendar allowlist for each account.
- Notify at most once per eligible host during normal polling and restarts with a persisted notification ID, five minutes before each matching occurrence; an ambiguous crash inside the external `Notify` call has the explicit at-least-once duplicate exception described below.
- Detect Google Meet and Zoom URLs without executing untrusted calendar text.
- Map each account label to its existing Firefox profile:
  - `upfront` to `default`
  - `sixfeetup` to `sixfeetup`
  - `alpha` to `clubhouse`
- Run on both `kiptum` and `kipchoge`, but notify only from a recently active local graphical session.
- Open the meeting in a new Firefox window on named Niri workspace `5`.
- Keep OAuth identities, calendar IDs, tokens, and event data outside the Nix store and repository.
- Provide useful local status and journal diagnostics without exposing sensitive data.

## Non-goals

- A general-purpose calendar application or agenda UI.
- Creating, editing, accepting, or declining events.
- Synchronizing calendars for other applications.
- Notifications for events without an approved Meet or Zoom URL.
- Hosted webhooks or Google Calendar push channels.
- Cross-host leader election or distributed notification deduplication.
- Launching the native Zoom client.
- Supporting compositors other than Niri in the first version.

## Existing context

Both Home Manager profiles import the desktop module and use Niri. They define persistent named workspaces, including workspace `5`. Noctalia is the active notification server; the pinned source implements freedesktop notification actions and emits `ActionInvoked` signals.

`modules/home/desktop/wayland/niri/config/firefox-profiles.sh` already establishes the repository's Firefox and Niri integration pattern. It gives each Firefox profile an app ID, snapshots Niri window IDs, launches Firefox, detects new windows, resolves named workspaces on the appropriate output, and moves windows through Niri IPC. The meeting launcher should reuse this behavior without changing profile startup.

Home Manager user-service patterns already exist under `modules/home/desktop/services/`. The new module belongs at `modules/home/desktop/services/meeting-notifier/` and should be imported from `modules/home/desktop/services/default.nix`.

## Adopt-versus-build decision

The implementation will use a narrow custom Go application built on maintained libraries rather than build a calendar client from first principles.

Google provides an official Go Calendar API client at `google.golang.org/api/calendar/v3`, OAuth support through `golang.org/x/oauth2`, and a maintained desktop OAuth quickstart. Go also produces a single executable that packages cleanly with `buildGoModule`.

The alternatives introduce more complexity or weaker contracts:

- `vdirsyncer` plus `khal` provides mature CalDAV and recurrence handling, but still needs a custom action daemon, loses the direct structured Calendar API contract, and adds local-calendar infrastructure that no other application currently needs.
- The pinned `gcalcli` supports conference fields in detailed output, but its `remind` command only passes aggregated start-time and title text to the invoked process. Getting a join URL would require parsing another output mode and managing isolated state for each account.
- Rust has maintained community clients, but Google does not list an official Calendar Rust client. Go therefore has lower integration and maintenance risk for this service.

## Architecture

The Home Manager module packages one Go program with three commands:

- `meeting-notifier setup <account-label>` performs desktop OAuth with forced consent, verifies the authenticated identity, atomically replaces one versioned authorization bundle for that label, and restarts the service after the bundle is durable.
- `meeting-notifier run` starts the long-lived synchronization and notification daemon.
- `meeting-notifier status` reports configuration health, account authorization state, selected calendar names, last successful poll, cache freshness, and the next matching meeting. It must redact tokens, event descriptions, and full meeting URLs.

The Go code is divided into focused packages with explicit interfaces:

- configuration and runtime-file loading;
- OAuth account setup and atomic per-account authorization-bundle persistence;
- Google Calendar polling;
- event filtering, URL selection, and occurrence identity;
- one-owner durable event cache and per-occurrence notification lifecycle state;
- logind activity detection;
- freedesktop notification delivery and action handling;
- invocation of the shared Firefox/Niri launcher;
- status reporting.

Google, DBus, process execution, time, and local state are kept behind narrow boundaries so reusable behavior can be tested without external services.

## Configuration and local state

Nix contains only stable, non-secret behavior: enablement, polling interval, lead time, workspace name, approved meeting hosts, and account-label-to-Firefox-profile mappings. The module is enabled explicitly for both Niri Home Manager profiles.

Runtime data is host-local:

- Each label has one versioned authorization bundle below the user's XDG data directory. The private `0600` bundle contains that label's OAuth client configuration, token, authenticated identity, selected calendar IDs, and a random generation value. OAuth client configuration is deliberately duplicated per label, so changing one label cannot invalidate another label's token.
- Token refresh updates acquire only that label's advisory file lock and compare the bundle generation before atomically replacing the whole bundle. A daemon that loaded an older generation cannot overwrite a later setup.
- Normalized upcoming-event snapshots, one lifecycle aggregate per relevant occurrence, and health metadata live below the XDG state directory. Snapshots retain only the event fields needed for filtering, display, deduplication, reconciliation, and joining rather than raw API responses.
- Directories use mode `0700`; credential and token files use mode `0600`.

`setup` authorizes each account label separately. It requests offline access with `prompt=consent` and fails without changing runtime data if Google omits the refresh token. After identity confirmation and calendar selection, it builds one `AuthorizationBundle` with schema version `1` and a new random generation, then atomically writes that label's single bundle under a per-label advisory lock. A failure before rename leaves the previous bundle intact; a sync/close failure after rename is durability-ambiguous and may leave the new complete bundle visible, but never exposes a partial bundle. Setup runs `systemctl --user restart meeting-notifier.service` only after the atomic writer reports success; any write or restart error is reported with rerun/restart guidance. Concurrent same-label setup is last-complete-write-wins, while different labels never share mutable authorization files. The daemon's refresh-token saver uses the same per-label lock and a generation compare-and-swap, so an old process cannot overwrite a newly authorized bundle during the short restart window.

Each host requires its own setup because tokens and state are intentionally not synchronized between machines.

## Service lifecycle

`meeting-notifier run` is a long-lived systemd user service tied to `graphical-session.target`. It maintains the session-bus connection needed to receive Noctalia's notification action signals. The generated JSON configuration is an `X-Restart-Triggers` input so Home Manager changes restart the daemon instead of leaving stale options loaded.

One event-loop goroutine owns the in-memory durable state for the process lifetime. Polling, activity, notification transport, and launcher workers never load or save state; they return immutable result events. Activity checks run in a bounded single worker so logind latency never blocks the owner. The owner applies one transition at a time, validates the resulting per-occurrence lifecycle, saves the whole state once, and only then dispatches newly enabled external effects. The only compensation exception is a failed save of an already-returned Notify result: the ordered notification dispatcher closes that uncommitted ID and exits, without another state writer or state write. This prevents last-writer-wins state loss.

The daemon connects each configured account independently. An account that is unconfigured, unauthorized, or temporarily failing does not block polling or notifications for other accounts.

The service refreshes a bounded upcoming-event snapshot every minute. A wider local horizon than the five-minute notification window preserves known events across short API or network outages. Each allowed calendar is queried with `singleEvents=true`, `orderBy=startTime`, and a bounded time range, allowing Google to expand recurring occurrences and apply event exceptions.

After every poll and on a local scheduling tick, the daemon evaluates cached events against the five-minute notification window. A newly active host can therefore notify for a meeting that entered the window while that host was idle, provided the meeting has not started.

## Event selection

The daemon ignores:

- cancelled events;
- events the authenticated user declined;
- all-day events;
- events that already started;
- events outside an account's calendar allowlist;
- events without an approved meeting URL.

Join URLs are selected in this order:

1. A video entry point from Google Calendar `conferenceData`.
2. `hangoutLink`.
3. An absolute URL parsed from the event location.
4. An absolute URL parsed from the event description.

The initial hostname allowlist is:

- `meet.google.com`
- `zoom.us`
- subdomains of `zoom.us`

A URL must use HTTPS, contain no user information, and match the hostname structurally. Query parameters and fragments are preserved because Zoom links may carry meeting credentials. Event text is never interpreted as a command, and URLs are never passed through a shell.

## Occurrence identity and deduplication

A non-recurring meeting occurrence is identified by account label, calendar ID, and Google event ID, which remains stable when the event is rescheduled. An expanded recurring instance is identified by account label, calendar ID, `recurringEventId`, and Google's `originalStartTime`; the mutable current start time is not part of the key. This distinguishes recurring instances, keeps a moved instance stable, and prevents repeated notifications across normal polling cycles and daemon restarts once a notification ID is durable; it does not remove the separate ambiguous external-Notify crash exception.

Each host keeps its own notification state. An idle host does not mark an occurrence as notified. If it becomes active before the meeting starts, it may send the notification. Cross-host coordination is intentionally absent; if both hosts simultaneously report recent input activity, both can notify.

Each occurrence has one durable aggregate containing its normalized meeting, lifecycle phase, notification ID when assigned, retry timing, action expiry, and phase-specific timestamps/reason. Legal phases are `scheduled`, `notify-pending`, `notified`, `actionable-history`, `join-pending`, `joined`, and `close-pending`; validation rejects fields that are invalid for the current phase. A notification-ID index is derived in memory from those aggregates and is never persisted separately.

After each successful account snapshot, the state owner reconciles occurrence aggregates against the authoritative normalized set. Cancellation, deletion, decline, URL removal, or rescheduling outside the lead window transitions the aggregate to `close-pending`, which immediately makes Join invalid and persists before the close effect runs. A rescheduled occurrence retains its stable key; if still due, changed URL or visible metadata re-enters `notify-pending` with the prior ID as its replacement target. Failed account refreshes retain the prior snapshot and produce no reconciliation transition.

`joined` is a non-actionable deduplication tombstone, so a later tick cannot recreate and renotify the cached occurrence. Old joined/history state is pruned only after the event ends or, when no end exists, two hours after start.

## Active-host behavior

The daemon inspects the current graphical session through logind over DBus. A session is eligible to notify when it is active and not idle. Both hosts continue polling and caching independently, but only an eligible session displays notifications.

If activity detection unexpectedly fails while a graphical session and notification server are available, the daemon fails open and sends the notification rather than silently missing a meeting. It logs the degraded activity check. This is a best-effort active-host policy, not distributed mutual exclusion.

## Notification behavior

The daemon calls `org.freedesktop.Notifications.Notify` directly and registers for `ActionInvoked` and `NotificationClosed` signals. The notification contains:

- meeting title;
- local start time;
- account label;
- a visible `Join` action.

### Join action flow

The Join action follows the freedesktop notification protocol end to end:

1. The state owner transitions the occurrence to `notify-pending`, persists it, and wakes the notification dispatcher.
2. The dispatcher calls `Notify` with `["join", "Join"]`, then rendezvous-delivers the result on the owner's unbuffered event ingress and waits on a capacity-one persistence-ack channel, selecting acknowledgement or context cancellation, before forwarding any subsequently queued DBus signal.
3. The state owner records the returned notification ID, transitions to `notified`, persists, derives the ID lookup, and acknowledges success. If persistence fails, it negatively acknowledges with a non-blocking send; the dispatcher attempts `CloseNotification` under a fresh bounded context, forwards no queued action, and returns the joined error. If cancellation wins the wait, the dispatcher exits and a late owner acknowledgement remains buffered rather than blocking shutdown.
4. Selecting Join emits `ActionInvoked(notificationID, "join")`; the owner resolves the derived lookup, validates action key, phase, expiry, and URL, transitions to `join-pending`, and persists before waking the launcher.
5. One launcher worker processes the oldest durable `join-pending` occurrence. Success transitions it to non-actionable `joined`; failure returns through its recorded prior phase. The owner performs the only resulting state write.
6. A close requested by reconciliation transitions to `close-pending` and invalidates Join before the DBus close command. A matching close signal completes that transition.
7. A spontaneous `NotificationClosed` caused by expiry, dismissal, or undefined notification-server behavior transitions `notified` to `actionable-history` and retains the ID/action until action expiry, matching Noctalia history behavior. A close signal never erases an in-flight `join-pending` transition.
8. Time-based pruning removes expired terminal/history aggregates.

On startup, the owner reloads lifecycle aggregates and resumes `notify-pending`, `join-pending`, and `close-pending` work one item per worker. Durable phases are the backlog; there is no fixed-capacity replay queue. Worker wake-ups are coalesced because the owner scans state again after every result. DBus signals and worker results use cancellable blocking sends into the always-draining event loop, so overload applies backpressure instead of dropping a valid signal or restarting the service. Notification, Calendar, and launcher operations use explicit deadlines. Restarting the notification server itself may invalidate outstanding IDs and is not guaranteed to preserve actions.

Persisting `notify-pending` before `Notify` prevents silent loss, but the freedesktop protocol cannot query an ambiguous result if the process dies after display and before persisting the returned ID. Delivery is therefore at-least-once across that narrow crash window and may produce one duplicate per ambiguous retry; repeated crashes can repeat that outcome. The design does not claim strict crash-safe at-most-once notification delivery. A failed delivery-result state write leaves durable `notify-pending` recoverable and triggers the ordered compensating-close acknowledgement path described above.

Noctalia may move expired or dismissed notifications into its history; the `actionable-history` phase keeps Join valid until action expiry unless reconciliation has already entered `close-pending`. Authentication warnings are actionless and rate-limited to at most one notification per account per day. Routine API, cache, and placement details remain in the systemd journal and `status` output rather than producing repeated desktop notifications.

## Firefox and Niri integration

Niri owns one packaged `niri-firefox-launcher` executable. The existing startup flow and meeting notifier both invoke it, so app-ID calculation, window snapshots, workspace/output resolution, and placement cannot drift. `launch-profile` preserves the existing startup behavior (`--new-instance`, two-second session-restore settle, all newly observed windows, no focus). `open-url` accepts workspace, profile, and URL as direct arguments, sets the same `MOZ_APP_REMOTINGNAME`/`MOZ_APP_LAUNCHER` profile app ID as startup mode, uses `--new-window`, selects only a newly observed exact matching window, moves/focuses it, and never evaluates URL text through a shell. The meeting daemon revalidates the URL immediately before direct-argv invocation.

The profile's ordinary Niri rule may initially route the new window to the profile's normal workspace. Post-launch placement then moves only the newly observed meeting window; existing profile windows are untouched.

If the window cannot be identified or moved before the bounded timeout, Firefox remains open wherever Niri routed it. The daemon logs the placement failure and does not close or relaunch the meeting window.

## Error handling and recovery

- HTTP `401`, stable authentication reasons from `googleapi.Error.Errors`, and `oauth2.RetrieveError.ErrorCode == "invalid_grant"` mark only the affected account as requiring setup.
- HTTP `429`, HTTP `403` reasons such as `rateLimitExceeded`, `userRateLimitExceeded`, and `quotaExceeded`, transport timeouts, and transient `5xx` responses use bounded exponential backoff with jitter; context cancellation remains cancellation rather than a retryable API error.
- A failed calendar refresh retains its last successful snapshot so a known imminent meeting can still notify.
- Bundle and state files use same-directory atomic replacement followed by parent-directory fsync. Pre-rename failures preserve the old file; post-rename failures are reported as durability-ambiguous while still guaranteeing that any visible file is complete.
- A syntactically corrupt cache or notification-state file is renamed for diagnosis and rebuilt at the explicit state-loading boundary. Permission, read, sync, close, rename, and other I/O failures propagate and stop execution; account, token, and OAuth JSON decoding failures are never silently recovered.
- A missing, malformed, or unsupported-version authorization bundle is reported loudly in `status` and the journal and disables only that account. A stale-generation token refresh returns a typed error without overwriting the bundle.
- A missing Noctalia notification endpoint is retried without marking occurrences as notified.
- Niri and Firefox failures are isolated to the selected Join action and do not terminate calendar polling.

Logs include account labels, calendar display names, event IDs, and error categories where useful, but omit tokens, descriptions, authorization codes, and complete join URLs.

## Security considerations

The Google OAuth scope is limited to `calendar.readonly`. The installed-application authorization flow uses a loopback listener on `127.0.0.1` with a random state value, offline access, and `prompt=consent`; setup rejects a response without a refresh token. Tokens are stored only after identity confirmation and with restrictive permissions.

Calendar content is untrusted input, including content from shared calendars and invitations. Hostname allowlisting, HTTPS enforcement, URL parsing, direct argument execution, and repeated validation at action time are required controls. Firefox profile names and Niri workspace names come from trusted Nix configuration rather than event data.

The Nix store and repository must not contain account email addresses, calendar IDs, OAuth refresh tokens, or event details. Stable account labels are sufficient for declarative profile mapping.

## Testing and verification

Automated Go tests cover behavior that could regress meaningfully:

- Meet and Zoom URL extraction, precedence, and hostname validation;
- event timing, cancellation, decline, all-day, and already-started filtering;
- stable recurring and non-recurring occurrence identity across rescheduling;
- notification replacement and reconciliation after URL changes, cancellation, deletion, decline, URL removal, or rescheduling;
- recoverable `notify-pending` lifecycle state and the documented ambiguous-crash duplicate boundary;
- multiple-account failure isolation;
- cached-event behavior during API failures;
- atomic authorization-bundle replacement, generation-checked refresh updates, token/runtime-file permissions, parent-directory fsync, corrupt-state quarantine, and fail-fast non-corruption I/O errors;
- sensitive-value redaction using concrete sentinel token and meeting URL values;
- account-to-profile mapping;
- actionless authentication warnings;
- validated per-occurrence lifecycle transitions, reason-specific notification closure, immediate action ordering, and durable pending Join replay;
- one-owner state persistence under concurrent poll/activity/signal/launcher results;
- cancellable blocking DBus delivery and coalesced worker wake-ups under slow consumers;
- shared launcher behavior for startup profiles and meeting URLs.

Integration tests use a fake Google HTTP server for pagination, recurring instances, rescheduling, cancellation, `401`, `403` rate-limit reasons, `429`, `5xx`, transport timeout, forced consent, and missing-refresh-token responses. Storage tests verify complete per-account bundle replacement, per-label lock/CAS refresh races, and cross-label isolation. Reducer and fake DBus/process tests verify serial state ownership, Notify-result-before-action ordering, lifecycle invariants, history closure, cancellable signal backpressure, durable backlog replay, and launcher behavior. Recorded Niri JSON verifies the shared launcher preserves startup routing and selects only the newly created matching meeting window.

Static Nix option values do not need dedicated tests under the Testing Value Gate. Module integration is verified directly through formatting, evaluation, and builds.

Required verification includes:

```sh
(cd modules/home/desktop/wayland/niri/firefox-launcher && go test -race ./... && go vet ./...)
(cd modules/home/desktop/services/meeting-notifier && go test -race ./... && go vet ./...)
bash -n modules/home/desktop/wayland/niri/config/firefox-profiles.sh
nix fmt -- --check modules/home/desktop/services/meeting-notifier/package.nix modules/home/desktop/services/meeting-notifier/default.nix modules/home/desktop/services/default.nix modules/home/desktop/wayland/niri/firefox-launcher/package.nix modules/home/desktop/wayland/niri/config/autostart.nix home/roche/kiptum.nix home/roche/kipchoge.nix
nix build .#homeConfigurations."roche@kiptum".activationPackage
nix build .#homeConfigurations."roche@kipchoge".activationPackage
nix flake check --accept-flake-config --print-build-logs
```

## Live smoke test

After activating one host:

1. Configure the shared desktop OAuth client.
2. Authorize `upfront`, `sixfeetup`, and `alpha` and select each calendar allowlist.
3. Create separate Google Meet and Zoom events six minutes ahead.
4. Confirm one notification appears at five minutes on the recently active host.
5. Select **Join** and verify the mapped Firefox profile opens a new window on workspace `5`.
6. Verify a declined event, cancelled event, and event without a supported URL do not notify.
7. Update a pending event's URL and confirm its existing notification changes rather than duplicates.
8. Interrupt network access after an event has entered the local cache and confirm the known event can still notify.
9. Repeat setup and the core Join check on the second host.

## Rollout and rollback

Implement and validate on one Niri host first, then enable the same module on the second. Each host is authorized separately.

The Home Manager module exposes an enable option. Disabling it removes and stops the user service while leaving host-local OAuth and state files intact, permitting quick rollback and later re-enablement. Runtime credentials are removed only by deleting the corresponding private account files below the XDG data directory; disabling the service must not silently revoke or delete them.
