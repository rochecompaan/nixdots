# Ziti Controller CA Trust Design

## Summary

Add the production OpenZiti controller's control-plane root CA to the shared NixOS trust store so Firefox and other TLS clients can validate `https://ziti-controller.siyavula.com/zac/` without profile-local certificate exceptions.

## Goals

- Trust the CA that currently anchors the ZAC HTTPS certificate chain.
- Verify the CA copied from Kubernetes against the independently supplied SHA-256 fingerprint before committing it.
- Make the trust available through the existing `security.pki.certificateFiles` mechanism.
- Preserve existing CA files because they represent different trust anchors.

## Non-goals

- Do not rotate or modify any OpenZiti certificate in Kubernetes.
- Do not mutate the production cluster; Kubernetes access is read-only.
- Do not clear Firefox HSTS state or certificate exceptions as part of this change.
- Do not rename or remove `ctrl-siyavula-com.crt` because it is a distinct OpenZiti edge-root CA and its original external dependency has not been established conclusively.
- Do not import the CA separately into individual Firefox profiles.

## Current State and Diagnosis

The production controller exposes one stable TLS chain at `ziti-controller.siyavula.com:443`:

1. `CN=openziti-controller-ctrl-plane-identity`
2. `CN=openziti-controller-ctrl-plane-intermediate`
3. `CN=openziti-controller-ctrl-plane-root`

The root is stored in the production cluster at:

- Namespace: `openziti`
- Secret: `openziti-controller-ctrl-plane-root-secret`
- Data keys: `ca.crt` and `tls.crt` contain the same root certificate
- SHA-256 fingerprint: `69:42:CD:49:D4:4D:DF:C0:C9:0E:81:C4:66:21:2B:70:2D:63:CA:F0:DE:CF:AC:EB:F9:E6:BE:AF:E0:4D:4A:99`
- Subject and issuer: `CN=openziti-controller-ctrl-plane-root`
- Validity: 2025-11-07 through 2035-11-15
- cert-manager revision: 1

Repeated TLS handshakes returned the same leaf certificate, and OpenSSL verified the chain against this root. The root, intermediate, and server identity have not rotated since their initial issuance.

The current NixOS CA bundle does not contain this control-plane root. It contains `modules/nixos/core/certs/ctrl-siyavula-com.crt`, but that certificate is a different trust anchor:

- Subject and issuer: `CN=openziti-controller-edge-root`
- SHA-256 fingerprint: `50:CF:60:68:DC:F9:37:F8:F5:6A:68:E4:D3:47:EF:6B:FA:0F:E1:2A:2B:72:69:D3:8E:BF:BA:F6:3D:6E:D1:E1`
- Validity: 2026-03-13 through 2036-03-20

It also does not match the separate Siyavula staging private CA, whose subject has always been `CN=siyavula-staging-ca`.

Firefox's `default` and `siyavula` profiles contain manual exceptions for the unchanged ZAC leaf certificate. The failing profile now reports HSTS, which prevents Firefox from relying on a certificate exception. Private browsing and another profile use separate profile security state, explaining the inconsistent behavior. System `curl` reproduces the underlying trust failure with `unable to get local issuer certificate`.

## Design

### Certificate asset

Create:

`modules/nixos/core/certs/ziti-controller-siyavula-com.crt`

The file will contain only the PEM-encoded certificate from `openziti/openziti-controller-ctrl-plane-root-secret` key `ca.crt`. No private key or other Secret data will be copied.

Before writing the file, decode the certificate into a temporary location and validate its SHA-256 fingerprint exactly against:

`69:42:CD:49:D4:4D:DF:C0:C9:0E:81:C4:66:21:2B:70:2D:63:CA:F0:DE:CF:AC:EB:F9:E6:BE:AF:E0:4D:4A:99`

Abort without changing Nixdots if the fingerprint differs.

### NixOS trust wiring

Modify `modules/nixos/core/security.nix` by adding:

```nix
./certs/ziti-controller-siyavula-com.crt
```

to `security.pki.certificateFiles`. Keep the existing `compaan-ca.crt` and `ctrl-siyavula-com.crt` entries.

This uses the repository's established CA integration pattern and makes the certificate available to the NixOS system CA bundle. Firefox is configured with `security.enterprise_roots.enabled = true`, so it can consume the system trust after activation and restart without relying on its stored leaf exception.

## Alternatives Considered

### Replace `ctrl-siyavula-com.crt`

Rejected because that file contains an edge-root CA with a different subject, key, fingerprint, and validity period. There is insufficient evidence that no remaining client depends on it.

### Import the CA into every Firefox profile

This narrows trust to Firefox, but duplicates state across profiles and excludes command-line and other system TLS clients. It also conflicts with the repository's existing system-wide CA pattern.

### Clear HSTS and retain certificate exceptions

This may restore access temporarily, but exceptions trust one leaf certificate rather than the issuing CA and will break under HSTS or certificate renewal. It does not fix system TLS clients.

## Error Handling and Safety

- Use only read-only `kubectl get` access with `./kubeconfigs/prod`.
- Extract only the public CA certificate; never write or print `tls.key`.
- Compare the normalized SHA-256 fingerprint before adding the file.
- Preserve all existing certificate assets and trust entries.
- Do not activate or deploy the NixOS configuration automatically.

## Verification

This is a static Nix configuration and certificate asset change. Per the Testing Value Gate, no new automated test is justified; direct cryptographic, lint, evaluation, and build verification provides stronger evidence.

1. Verify the committed certificate:

   ```sh
   openssl x509 \
     -in modules/nixos/core/certs/ziti-controller-siyavula-com.crt \
     -noout -subject -issuer -dates -fingerprint -sha256
   ```

   Expected fingerprint:

   `69:42:CD:49:D4:4D:DF:C0:C9:0E:81:C4:66:21:2B:70:2D:63:CA:F0:DE:CF:AC:EB:F9:E6:BE:AF:E0:4D:4A:99`

2. Verify the live leaf and intermediate against the new root with `openssl verify -purpose sslserver`.

3. Run the repository formatter check:

   ```sh
   nix fmt -- --check .
   ```

4. Run the repository-prescribed Nix linter:

   ```sh
   statix check .
   ```

   `statix` is not currently available in the shell or the repository dev shell. Implementation must pause for permission to fetch it through Nix, or for the user to provide an available linter, before completion.

5. Run the full flake evaluation and checks:

   ```sh
   nix flake check
   ```

6. Build one affected NixOS system closure without activating it:

   ```sh
   nix build .#nixosConfigurations.kiptum.config.system.build.toplevel
   ```

7. After the user activates the configuration and restarts Firefox, confirm that ZAC loads without relying on a certificate exception. No HSTS clearing should be required once the chain is trusted.

## Rollout

Merge and activate through the repository's normal NixOS deployment flow. Firefox must be restarted after activation so it reloads enterprise roots from the updated system trust store. Existing profile-local certificate exceptions may be removed later as optional cleanup, but their removal is not required for correctness and is outside this change.
