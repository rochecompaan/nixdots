# Zoom Web Client Join Design

## Goal

Make meeting-notifier's **Join** action open standard Zoom meeting links directly in Zoom's browser client, bypassing Zoom's intermediate app-versus-browser choice page.

## Scope

The change applies to every validated Zoom host: `zoom.us` and proper subdomains such as `sixfeetup.zoom.us`. It changes only the URL passed to the browser when the user invokes **Join**. Calendar normalization and durable meeting state continue to retain the original source URL.

Google Meet URLs and Zoom URLs that do not have the standard `/j/<numeric-meeting-id>` shape retain their existing launch behavior.

## URL transformation

After validating the latest meeting URL against the configured HTTPS host allowlist, meeting-notifier will recognize a Zoom URL only when:

- the normalized hostname is exactly `zoom.us` or ends with `.zoom.us` on a label boundary;
- the path is exactly `/j/<meeting-id>`;
- `<meeting-id>` contains ASCII decimal digits only; and
- there are no extra or trailing path segments.

A matching URL is transformed as follows:

```text
https://<original-host>/j/<meeting-id>?pwd=<password>
```

becomes:

```text
https://<original-host>/wc/<meeting-id>/start?ref_from=launch&fromPWA=1&pwd=<password>
```

The original host is preserved. The `pwd` query value is preserved when present and encoded through Go's URL APIs. Other source query parameters and fragments are discarded. Query parameter ordering is not part of the contract.

A validated URL that does not match these rules is returned unchanged. This includes personal-room, registration, existing web-client, and future Zoom URL shapes.

## Architecture and data flow

A focused pure transformer will live in the meeting domain beside the existing URL policy, in a separate provider-specific module so generic validation and text extraction remain cohesive.

The launcher client will perform this action-time sequence:

1. Validate the latest stored meeting URL with `meeting.ValidateURL` and the configured allowlist.
2. Pass the validated URL through the Zoom web-client transformer.
3. Validate the resulting URL again with the same policy.
4. Pass the final URL as one opaque argv value to `niri-firefox-launcher`.

No shell is introduced. The canonical Firefox/Niri launcher continues to own profile routing, workspace placement, and process behavior.

## Safety and failure behavior

Structural hostname checks prevent deceptive hosts such as `zoom.us.evil.example` from being rewritten. The existing allowlist validation rejects unapproved hosts, non-HTTPS URLs, and URL user information before transformation. Revalidation after transformation preserves the action-time defense-in-depth boundary.

If parsing or validation fails, **Join** returns through the existing launcher error path and does not execute Firefox. Nonmatching but valid Zoom URLs fall back to their original validated URL rather than failing.

## Testing

Implementation will follow strict red-green-refactor TDD.

Pure transformation tests will cover:

- `zoom.us` and proper Zoom subdomains;
- exact numeric `/j/<meeting-id>` recognition;
- preservation and correct encoding of `pwd`;
- fixed `ref_from=launch` and `fromPWA=1` values;
- removal of unrelated query parameters and fragments;
- unchanged Google Meet, `/my/...`, registration, and existing `/wc/...` URLs;
- unchanged malformed or nonnumeric Zoom paths; and
- rejection or non-rewrite of deceptive hostnames through the existing validation boundary.

Launcher-client tests will prove that the rewritten URL is revalidated and delivered as a single direct argv value. The complete meeting-notifier race suite, Go formatting, Go vet, relevant Nix package build, affected Home Manager activation builds, and full flake check will provide completion evidence.

## Non-goals

- Changing Calendar polling or stored meeting URLs.
- Supporting Zoom personal-room or registration URL conversion.
- Changing Google Meet behavior.
- Adding a configurable provider rewrite framework.
- Modifying the reusable Firefox/Niri launcher protocol.
