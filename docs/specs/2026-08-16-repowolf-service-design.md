# RepoWolf Home Service Design

## Status

Approved on 2026-08-16.

Revised after review to use a Home Manager service and the existing SSH agent.

## Context

RepoWolf is a repository access broker for Git and forge tools. It keeps provider credentials outside untrusted agent sandboxes.

The `kipchoge` and `kiptum` hosts need one service for the `roche` user. Pi jails and Docker containers will use that service.

Both hosts already run Docker with `172.17.0.1/16` as the default bridge. Both Home Manager profiles also enable GPG SSH-agent support.

The service must use the SSH agent of the user. It must not copy SSH private keys into a separate service account.

## Goals

- Run RepoWolf as a Home Manager user service on `kipchoge` and `kiptum`.
- Bind each service only to `172.17.0.1:8443`.
- Keep each service available to host processes, Pi jails, and Docker containers.
- Do not expose the listener on the LAN or through Ziti.
- Use the GPG or 1Password SSH agent of the `roche` user.
- Give each repository a separate principal.
- Restrict each principal to one exact repository.
- Use a shared policy structure on both hosts.
- Use different client token values on each host.
- Keep GitHub tokens, client tokens, and TLS private keys outside the Nix store.
- Emit sanitized audit events to the user journal.
- Document the client contract without changing client integration.

## Non-goals

- Do not change the `roche-pi` repository.
- Do not change jailed-Pi or container client code.
- Do not create a NixOS RepoWolf service.
- Do not add a custom host address or NixOS network rule.
- Do not create a dedicated `repowolf` operating-system user.
- Do not deploy provider SSH private keys.
- Do not run the RepoWolf OCI image.
- Do not provide a shared endpoint across the two hosts.
- Do not provide failover between the two services.
- Do not provide boot-time service availability before the user manager starts.
- Do not expose GitHub API operations for `git.compaan` repositories.
- Do not add `agent-jails` or `scaf` to the initial policy.

## Selected approach

Add RepoWolf as a flake input. Use its native Nix package in a shared Home Manager module.

The module will create one `systemd --user` service per enabled profile. The `roche@kipchoge` and `roche@kiptum` profiles will enable it.

Each service will bind to `172.17.0.1:8443`. Host processes and containers can reach this Docker bridge address.

The listener will not bind to `127.0.0.1`, the LAN address, or the Ziti address. RepoWolf supports one listen address.

The service will run as `roche`. It will pass `SSH_AUTH_SOCK` to RepoWolf for provider Git operations.

RepoWolf removes `REPOWOLF_*` variables from provider subprocess environments. It preserves `SSH_AUTH_SOCK` and `GH_TOKEN`.

## Repository structure

The implementation will add these files:

```text
modules/home/desktop/services/repowolf/
├── README.md
├── default.nix
├── policy.nix
└── tls/
    ├── kipchoge-ca.crt
    ├── kipchoge.crt
    ├── kiptum-ca.crt
    └── kiptum.crt
```

The implementation will also change these files:

```text
flake.nix
flake.lock
home/roche/kipchoge.nix
home/roche/kiptum.nix
modules/home/desktop/services/default.nix
```

The implementation will also update `secrets.yaml` in `/home/roche/projects/nix-secrets`. The new private revision will be pinned in `flake.lock`.

The implementation will not change NixOS host modules or client integration modules.

## Flake input

The flake will add `github:rochecompaan/repowolf` as an input. The RepoWolf input will follow the `nixpkgs` input of this repository.

The service package will use this path:

```nix
inputs.repowolf.packages.${pkgs.system}.repowolf
```

The service will use absolute Nix store paths for these tools:

```nix
${pkgs.gh}/bin/gh
${pkgs.openssh}/bin/ssh
```

RepoWolf will not resolve provider tools from a mutable runtime `PATH`.

## Home Manager module

The module will define these options:

- `services.repowolf.enable`
- `services.repowolf.hostName`
- `services.repowolf.package`
- `services.repowolf.sshAuthSock`

The enable option will be false by default. The host name will be either `kipchoge` or `kiptum`.

The host profiles will set the host name explicitly. This keeps the standalone Home Manager outputs independent from NixOS module arguments.

The package option will default to the RepoWolf flake package. The SSH-agent option will permit a path override for 1Password.

If the SSH-agent option is empty, the service launcher will get the GPG SSH-agent socket from `gpgconf`.

When enabled, the module will configure these resources:

- the strict RepoWolf YAML configuration
- the service environment from a sops-nix template
- the host TLS certificate and private-key paths
- the `repowolf.service` user unit
- the RepoWolf administration package

The module will assert that the host name is supported. It will also assert that required configuration values are not empty.

## Service configuration

The module will generate strict YAML with `pkgs.formats.yaml`. The generated file can stay in the Nix store because it contains no secret values.

The Home Manager profile will expose the file at this path:

```text
$XDG_CONFIG_HOME/repowolf/repowolf.yaml
```

The configuration will contain:

- API version `repowolf.dev/v1alpha1`
- listener `172.17.0.1:8443`
- the host certificate path
- the sops-nix private-key path
- absolute paths for `gh` and `ssh`
- the two providers
- the twelve repositories
- the twelve principals

RepoWolf will use its default resource limits. The policy will set repository-specific Git push limits.

## Docker bridge dependency

Both target hosts currently use these Docker bridge values:

```text
gateway: 172.17.0.1
subnet: 172.17.0.0/16
```

The user service will depend on this existing address. The implementation will not change the Docker bridge configuration.

A service start will fail if Docker has not created the bridge. The restart policy will retry after a short delay.

A future Docker bridge change must include a matching RepoWolf listener and certificate change.

## Providers

### GitHub

The `github-public` provider will use these values:

```yaml
kind: github
apiHost: github.com
gitHost: github.com
sshUser: git
```

This provider supports the approved GitHub API and Git SSH capabilities.

### git.compaan

The `compaan` provider will use these values:

```yaml
kind: github
apiHost: git.compaan
gitHost: git.compaan
sshUser: git
```

The two `git.compaan` principals will receive only Git capabilities. RepoWolf will not call the GitHub adapter for these principals.

RepoWolf constructs Git SSH commands from `gitHost`, `sshUser`, and `sshPort`. This behavior permits Git operations against `git.compaan`.

## Capability sets

The `github-agent` capability set contains:

```text
repository:read
issues:read
issues:write
pull_requests:read
pull_requests:write
actions:read
statuses:read
git:read
git:write
```

The `git-only-agent` capability set contains:

```text
git:read
git:write
```

RepoWolf does not grant pull-request merge, repository administration, release administration, or workflow dispatch through these sets.

## Repository policy

Each principal has one token environment variable and one repository grant.

| Principal | Token environment | Provider | Repository | Default branch | Capability set |
|---|---|---|---|---|---|
| `clubhouse-infra` | `REPOWOLF_TOKEN_CLUBHOUSE_INFRA` | `github-public` | `alphaexplorationco/clubhouse_infra` | `main` | `github-agent` |
| `clubhouse-server` | `REPOWOLF_TOKEN_CLUBHOUSE_SERVER` | `github-public` | `alphaexplorationco/clubhouse_server` | `main` | `github-agent` |
| `clubhouse-analytics` | `REPOWOLF_TOKEN_CLUBHOUSE_ANALYTICS` | `github-public` | `alphaexplorationco/clubhouse_analytics` | `main` | `github-agent` |
| `croprun` | `REPOWOLF_TOKEN_CROPRUN` | `compaan` | `roche/croprun` | `main` | `git-only-agent` |
| `agibase` | `REPOWOLF_TOKEN_AGIBASE` | `github-public` | `upfrontsoftware/agibase` | `master` | `github-agent` |
| `repowolf` | `REPOWOLF_TOKEN_REPOWOLF` | `github-public` | `rochecompaan/repowolf` | `main` | `github-agent` |
| `nixdots` | `REPOWOLF_TOKEN_NIXDOTS` | `github-public` | `rochecompaan/nixdots` | `main` | `github-agent` |
| `homelab-k8s` | `REPOWOLF_TOKEN_HOMELAB_K8S` | `github-public` | `rochecompaan/homelab-k8s` | `main` | `github-agent` |
| `patchmill` | `REPOWOLF_TOKEN_PATCHMILL` | `github-public` | `rochecompaan/patchmill` | `main` | `github-agent` |
| `mycity` | `REPOWOLF_TOKEN_MYCITY` | `github-public` | `upfrontsoftware/mycity` | `main` | `github-agent` |
| `siyavula-deploy` | `REPOWOLF_TOKEN_SIYAVULA_DEPLOY` | `github-public` | `Siyavula/deploy` | `master` | `github-agent` |
| `roche-pi` | `REPOWOLF_TOKEN_ROCHE_PI` | `compaan` | `roche/pi-config` | `main` | `git-only-agent` |

Every repository will use this Git policy:

- deny direct updates to its listed default branch
- deny all ref deletions
- limit one push to 16 ref updates

The service will reject a token that requests a different repository. The service will also reject capabilities outside the grant for the principal.

## Secret model

The module will read encrypted values from this private flake input:

```nix
${inputs.nix-secrets}/secrets.yaml
```

This matches the existing jailed-agent and Streamlinear secret pattern. Add the encrypted values in `/home/roche/projects/nix-secrets/secrets.yaml`.

Secret values will not enter the Nix store or unencrypted repository files.

The secret hierarchy will use these groups:

```text
repowolf/providers/github/token
repowolf/tls/kipchoge/private-key
repowolf/tls/kiptum/private-key
repowolf/tokens/kipchoge/PRINCIPAL_ID
repowolf/tokens/kiptum/PRINCIPAL_ID
```

`PRINCIPAL_ID` means a principal identifier from the policy table.

There will be 24 client token values. Each host will have a different value for each of the twelve principals.

The service environment template will map host-specific token values to the common token environment names. It will also set `GH_TOKEN`.

The environment template will not contain an SSH private key. The service will use `SSH_AUTH_SOCK` for Git SSH authentication.

A sops-nix change will restart `repowolf.service`. The restart is necessary because RepoWolf loads secrets only at startup.

## SSH-agent model

The service runs with the same UID as the GPG or 1Password SSH agent. It can connect to the protected agent socket.

For the current GPG configuration, the launcher will resolve the socket with this command:

```sh
gpgconf --list-dirs agent-ssh-socket
```

The `services.repowolf.sshAuthSock` option can replace this path. A 1Password configuration can use its user-owned agent socket.

The service launcher will export `SSH_AUTH_SOCK` before it starts RepoWolf. RepoWolf will preserve this variable for its `ssh` subprocesses.

The agent socket will not enter the client configuration. Pi jails and containers must never mount or inherit it.

The service will use the normal SSH configuration and known-host data of the user. The user remains inside the trusted service boundary.

## TLS model

Each host will have a separate private CA and a separate server private key. Both server certificates will contain these subject alternative names:

```text
DNS:repowolf.internal
DNS:host.docker.internal
IP:172.17.0.1
```

Use RepoWolf to create each initial certificate set:

```sh
repowolf cert init \
  --output "$OUTPUT_DIRECTORY" \
  --dns repowolf.internal \
  --dns host.docker.internal \
  --ip 172.17.0.1
```

Store each server private key in sops-nix. Commit only the public CA certificate and public server certificate.

Keep each CA private key outside the deployed hosts and this repository. The service does not need a CA private key.

Clients will receive only the public CA certificate for their current host. A certificate change will restart the service.

## systemd user service

The unit will run as `roche` and start from `default.target`. It will stop when the user manager stops.

The unit will use these commands:

```text
repowolf config validate --config $XDG_CONFIG_HOME/repowolf/repowolf.yaml
repowolf serve --config $XDG_CONFIG_HOME/repowolf/repowolf.yaml
```

The launcher will set `SSH_AUTH_SOCK` before these commands. The service environment file will provide `GH_TOKEN` and the client token variables.

The unit will use these systemd controls:

- `NoNewPrivileges=true`
- `PrivateTmp=false`
- `Restart=on-failure`
- `RestartSec=5s`
- a restrictive file-creation mask

The unit will not use `ProtectHome=true`. RepoWolf and its provider tools need the user SSH configuration and agent integration. The target-host provider SSH transport requires the host temporary namespace.

RepoWolf writes audit JSON Lines to standard output. The user journal will collect these events under `repowolf.service`.

## Runtime flow

1. A client connects to `https://172.17.0.1:8443` or `https://host.docker.internal:8443`.
2. TLS proves the identity of the user service.
3. RepoWolf maps the bearer token to one principal.
4. RepoWolf checks the exact repository and requested capability.
5. RepoWolf invokes the pinned `gh` or `ssh` executable.
6. `gh` uses the service `GH_TOKEN`.
7. `ssh` uses the user-owned SSH agent through `SSH_AUTH_SOCK`.
8. RepoWolf returns normalized output to the client.
9. RepoWolf writes a sanitized audit event to the user journal.

The client never receives provider tokens, the SSH-agent socket, service policy, or TLS private keys.

## Client documentation

`modules/home/desktop/services/repowolf/README.md` will document the service contract. It will not configure a client.

The README will document:

- host endpoint `https://172.17.0.1:8443`
- Docker endpoint `https://host.docker.internal:8443`
- the Linux Docker `host-gateway` name mapping
- required public CA file
- one host-specific token for one repository principal
- `REPOWOLF_ENDPOINT`
- `REPOWOLF_TOKEN`
- `REPOWOLF_CA_FILE`
- optional `REPOWOLF_SERVER_NAME`
- `GIT_SSH_COMMAND=repowolf-git-ssh`
- the client-only RepoWolf package
- the requirement that the restricted `gh` comes first in `PATH`
- the Git-only limit for `croprun` and `roche-pi`
- the prohibition against mounting provider credentials or `SSH_AUTH_SOCK` into clients

The separate client-integration session owns all client code and client configuration changes.

## Failure handling

RepoWolf will fail closed when the configuration, token values, certificates, or provider tools are invalid. The unit will not accept traffic in this state.

An invalid configuration will fail during `ExecStartPre`. Missing runtime inputs will fail during service startup.

If `172.17.0.1` does not exist, RepoWolf cannot bind the listener. Systemd will retry the user service.

A client with an unknown token will receive an authentication error. A cross-repository request will receive an authorization error.

A direct update to a protected default branch will fail before the provider receives the update. A ref deletion will also fail.

A GitHub API request for a `git.compaan` principal will fail policy authorization. The service will not call `gh` for that request.

If the SSH agent is locked or unavailable, a Git operation will fail. The provider private key will not fall back to a file.

## Security properties

- RepoWolf listens only on the Docker bridge address.
- RepoWolf does not listen on the LAN or Ziti address.
- TLS is mandatory for every client connection.
- Each token grants access to one repository.
- Client token values differ between hosts.
- Provider credentials stay in the user service boundary.
- Clients cannot access the user SSH-agent socket.
- RepoWolf uses pinned provider executables.
- The policy contains exact repositories and no wildcards.
- Audit records exclude credentials and sensitive request bodies.

The `roche` account and its normal processes remain trusted. Clients and all client request fields remain untrusted.

## Verification strategy

The change is static Home Manager configuration. New tests that assert Nix or YAML text do not pass the Testing Value Gate.

Use direct evaluation, build, validation, and runtime checks instead.

### Before activation

Run these commands from this repository:

```sh
nix build '.#homeConfigurations."roche@kipchoge".activationPackage'
nix build '.#homeConfigurations."roche@kiptum".activationPackage'
nix flake check --accept-flake-config --print-build-logs
```

Build each generated RepoWolf configuration. Then run `repowolf config validate` against each file.

Make sure that each generated policy contains twelve principals and twelve repositories. Do not print decrypted token values.

### After activation

Make sure that these checks pass on each host:

- `repowolf.service` is active in the user manager.
- The service listens only on `172.17.0.1:8443`.
- The certificate is valid for `172.17.0.1` and `host.docker.internal`.
- RepoWolf passes the configured SSH-agent socket to provider subprocesses.
- A valid token can access only its repository.
- The same token cannot access another repository.
- An unknown token fails authentication.
- A protected-branch update fails.
- A ref deletion fails.
- A `git.compaan` token cannot use GitHub API operations.
- The user journal contains sanitized accepted and denied audit events.
- The service environment does not appear in logs.

## Acceptance criteria

The design is complete when all of these conditions are true:

- Both Home Manager activation packages build with RepoWolf enabled.
- Each host has one active RepoWolf user service while the user manager runs.
- Each service binds only to `172.17.0.1:8443`.
- No NixOS networking or service change is present.
- Both services use the same policy structure.
- Each service uses 12 host-specific client token values.
- Each principal grants access to exactly one repository.
- The two `git.compaan` principals have Git-only capabilities.
- Git SSH operations use the user SSH agent.
- No provider SSH private key is deployed.
- Provider credentials and TLS private keys remain outside the Nix store.
- The service README documents the client contract.
- No client integration file changes in this work.
- The flake check passes.
- The runtime checks pass on both activated hosts.

## References

- `/home/roche/projects/repowolf/README.md`
- `/home/roche/projects/repowolf/docs/specs/2026-08-01-repowolf-mvp-design.md`
