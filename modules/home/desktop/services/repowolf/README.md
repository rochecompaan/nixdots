# RepoWolf Home Service

This module runs RepoWolf as the `roche` Home Manager user on `kipchoge` and `kiptum`.
It does not configure RepoWolf clients.

## Endpoints

| Client location | Endpoint |
|---|---|
| Host process | `https://172.17.0.1:8443` |
| Docker container | `https://host.docker.internal:8443` |

On Linux, validate the Docker host mapping with this command:

```sh
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  alpine:3.22 \
  getent hosts host.docker.internal
```

Each host has a different public CA file at `~/.config/repowolf/tls/ca.crt`.
Give a client only the CA for its current host.

## Client contract

Each client gets one host-specific token for one repository principal.
It also gets the public CA for that host.

```sh
export REPOWOLF_ENDPOINT=https://172.17.0.1:8443
export REPOWOLF_TOKEN="$(cat /run/secrets/repowolf-token)"
export REPOWOLF_CA_FILE=/run/secrets/repowolf-ca.crt
export GIT_SSH_COMMAND=repowolf-git-ssh
```

A Docker client uses `https://host.docker.internal:8443` instead.
`REPOWOLF_SERVER_NAME` is optional because both approved endpoint names exist in the certificate.

Use `inputs.repowolf.packages.${pkgs.system}.repowolf-client` in Nix-managed clients.
Put that package's restricted `gh` before any unrestricted `gh` in `PATH`.

## Principal map

| Principal | Provider | Repository |
|---|---|---|
| `clubhouse-infra` | `github-public` | `alphaexplorationco/clubhouse_infra` |
| `clubhouse-server` | `github-public` | `alphaexplorationco/clubhouse_server` |
| `clubhouse-analytics` | `github-public` | `alphaexplorationco/clubhouse_analytics` |
| `croprun` | `compaan` | `roche/croprun` |
| `agibase` | `github-public` | `upfrontsoftware/agibase` |
| `repowolf` | `github-public` | `rochecompaan/repowolf` |
| `nixdots` | `github-public` | `rochecompaan/nixdots` |
| `homelab-k8s` | `github-public` | `rochecompaan/homelab-k8s` |
| `patchmill` | `github-public` | `rochecompaan/patchmill` |
| `mycity` | `github-public` | `upfrontsoftware/mycity` |
| `siyavula-deploy` | `github-public` | `Siyavula/deploy` |
| `roche-pi` | `compaan` | `roche/pi-config` |

## Security boundaries

- `croprun` can use only `git:read` and `git:write` for `roche/croprun` on `git.compaan`.
- `roche-pi` can use only `git:read` and `git:write` for `roche/pi-config` on `git.compaan`.
- Every other principal has the approved GitHub and Git capabilities for one repository.
- A client must not receive `GH_TOKEN`, provider SSH keys, or the service `SSH_AUTH_SOCK`.
- A client must not mount the service environment, policy, certificate private key, or SSH-agent socket.
- Client integration belongs to a separate implementation session.
