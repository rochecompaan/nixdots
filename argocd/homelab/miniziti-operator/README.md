# miniziti-operator

This ArgoCD app deploys the upstream `miniziti-operator` install bundle and is
also the place for your declarative OpenZiti resources:

- `ZitiIdentity`
- `ZitiService`
- `ZitiAccessPolicy`

## Management secret

Generate the sealed management Secret with:

```sh
just seal-openziti-management-secret
```

This target depends on `just ziti-edge-login`, which logs into:

```sh
ziti edge login ctrl.compaan.cloud:443 -u "admin" -p "$(pass show private/login/zac-ctrl.compaan.cloud-admin | head -n1)"
```

The recipe accepts these environment variables:

- `OPENZITI_CONTROLLER_URL` (default: `https://ctrl.compaan.cloud/edge/management/v1`)
- `OPENZITI_USERNAME` (default: `admin`)
- `OPENZITI_PASSWORD` (default: `pass show private/login/zac-ctrl.compaan.cloud-admin | head -n1`)
- `OPENZITI_CA_BUNDLE_FILE` (optional path to a PEM CA bundle)

The sealed secret is written to:

- `argocd/homelab/miniziti-operator/openziti-management-secret.yaml`

## Declarative resources

Add `ZitiIdentity`, `ZitiService`, and `ZitiAccessPolicy` manifests anywhere in
this directory tree. The ArgoCD Application is configured with
`directory.recurse: true`, so subdirectories are applied automatically.
