# Meeting notifier operations

The Home Manager module runs an actionable Google Calendar notifier on the Niri
desktop. Its reusable configuration contains account labels and Firefox profile
names only. OAuth clients, tokens, account identities, selected calendar IDs,
event snapshots, and notification state stay in the user's XDG data/state
directories and never enter this repository or the Nix store.

## Zoom web-client joins

When **Join** receives a standard `https://<zoom-host>/j/<numeric-id>` URL,
meeting-notifier opens `https://<zoom-host>/wc/<numeric-id>/start` directly in
the configured Firefox profile. It preserves the Zoom `pwd` value and sets the
browser-client launch parameters. Other validated Zoom URL shapes and Google
Meet URLs open unchanged.

## Google OAuth setup

1. In a Google Cloud project, enable the Google Calendar API.
2. Configure the OAuth consent screen. Allow the Google identities used by all
   three deployed labels (`upfront`, `sixfeetup`, and `alpha`) according to the
   app's audience/testing configuration.
3. Create an OAuth client with application type **Desktop app** and download its
   credential JSON.
4. Copy the JSON to a temporary private path outside this repository and the Nix
   store. Restrict access to the current user, for example:

   ```sh
   install -m 600 /path/to/downloaded-client.json /private/path/credentials.json
   ```

On each host, authorize each label from a graphical terminal:

```sh
meeting-notifier setup --credentials /private/path/credentials.json upfront
meeting-notifier setup --credentials /private/path/credentials.json sixfeetup
meeting-notifier setup --credentials /private/path/credentials.json alpha
meeting-notifier status
systemctl --user status meeting-notifier.service
journalctl --user -u meeting-notifier.service
```

Each setup opens the consent flow with offline access and forced consent. Confirm
that the authenticated identity is the intended account for the label, then
select only calendars whose meetings should produce notifications. Delete the
temporary credential file when all setup commands have succeeded; the private
versioned bundles contain the client and refresh tokens needed at runtime.

The deployed label-to-profile routes are:

- `upfront` -> Firefox profile `default`
- `sixfeetup` -> Firefox profile `sixfeetup`
- `alpha` -> Firefox profile `clubhouse`

## Storage and setup lifecycle

Static configuration is Home Manager-managed at
`$XDG_CONFIG_HOME/meeting-notifier/config.json` (normally
`~/.config/meeting-notifier/config.json`). Authorization bundles are below
`$XDG_DATA_HOME/meeting-notifier/accounts` (normally
`~/.local/share/meeting-notifier/accounts`), and event/notification state is at
`$XDG_STATE_HOME/meeting-notifier/state.json` (normally
`~/.local/state/meeting-notifier/state.json`). Runtime-created directories are
forced to mode `0700`; bundle, state, and lock files are mode `0600`.

Each label is one complete versioned authorization bundle. A successful setup
atomically replaces only that label's bundle and then restarts
`meeting-notifier.service` after the write reports success. A failure before
rename preserves the old bundle. A sync or close failure after rename is
durability-ambiguous, but leaves only complete old-or-new content, never a
partial bundle. Any write or restart error prints guidance to rerun setup/status
or restart the service manually. Inspect the redacted summary with
`meeting-notifier status`; use the systemd status and journal commands above for
service diagnostics.

Freedesktop `Notify` has an unavoidable external ambiguity: if the notification
server processes a request and the call then fails before the notifier observes
the reply, recovery may display a bounded duplicate. Strict at-most-once
delivery is therefore not guaranteed across that crash boundary.

## Reauthorization

Rerun the same setup command for the affected label. Setup always requests
forced consent and requires a refresh token. Reconfirm the identity, select only
the intended calendars, and then verify the automatic restart:

```sh
meeting-notifier setup --credentials /private/path/credentials.json upfront
meeting-notifier status
systemctl --user status meeting-notifier.service
```

Use the corresponding label for another account. If setup reports that the
bundle was written but restart failed, run:

```sh
systemctl --user restart meeting-notifier.service
meeting-notifier status
```

## Rollback and credential removal

Set the following in the host's Home Manager profile and activate it to remove
the package, generated configuration, and user service while preserving the XDG
data and state for a later rollback:

```nix
services.meetingNotifier.enable = false;
```

Disabling the module does not delete credentials. To remove credentials
permanently, stop the service first, verify that it is no longer running, and
only then remove the notifier directory below `XDG_DATA_HOME`:

```sh
systemctl --user stop meeting-notifier.service
systemctl --user is-active meeting-notifier.service
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/meeting-notifier"
```

The state directory is separate and contains cached event and notification
state, not OAuth credentials. Remove it only if a completely fresh state is
also wanted, while the service remains stopped:

```sh
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/meeting-notifier"
```

## Live smoke test (operator-only)

These checks require real OAuth, Google Calendar data, Noctalia, logind,
Firefox, Niri, and user-systemd activation. They are intentionally not automated
or implied by Nix/Go verification. Activate and authorize one host first, then:

1. Confirm `meeting-notifier status`, systemd status, and the journal are clean.
2. Keep that host's local graphical session active and the other host idle;
   create near-term meetings and confirm only the active host notifies. Repeat
   with host activity reversed. Confirm degraded logind lookup fails open rather
   than suppressing notifications and the journal warning contains exactly the
   stable diagnostic fields `component=activity category=degraded` (with no
   underlying error details).
3. For each label, invoke **Join** and confirm the new Firefox window uses the
   exact mapping above, moves to named Niri workspace `5`, and focuses without
   moving or reusing an existing window.
4. Confirm the notification is withdrawn or not emitted after each live
   lifecycle change: cancellation, deletion, decline, and meeting URL removal.
5. Confirm rescheduling outside the lead window withdraws the old notification
   and rescheduling back produces the correct current occurrence behavior.
6. Change the meeting URL before joining and confirm Join uses only the updated,
   revalidated HTTPS URL. Exercise allowed Google Meet, Zoom, and Zoom subdomain
   URLs and reject unrelated hosts or URLs containing user information.
7. Interrupt Google Calendar networking after a successful poll. Confirm cached
   meetings within the 24-hour horizon continue to notify, status reports
   `last-error=transient`, and the journal warning contains the stable fields
   `component=poll account=<label> category=transient` without the underlying
   error. Authentication and rate-limit failures use `category=authentication`
   and `category=rate-limit`. Confirm recovery does not duplicate completed
   lifecycle effects beyond the documented ambiguous `Notify` window.
8. Observe Noctalia's Join action, ActionInvoked/NotificationClosed/history
   behavior, and notification replacement/closure directly.

After the first host passes, activate and authorize the second host and repeat
the host-specific profile routing, workspace placement, and activity-gating
checks. Record these live results separately; source builds cannot verify them.
