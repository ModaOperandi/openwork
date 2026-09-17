# OpenWork EE Helm Chart

Initial Helm chart for the OpenWork EE Den stack:

- `den-api` control plane on port `8788`
- `den-web` web app on port `3005`
- optional `inference` service on port `8791`
- shared ConfigMap and Secret templating
- optional Ingress for web and API hosts
- pre-install/pre-upgrade migration Job scaffold

## Install

Published releases are available as an OCI Helm chart:

```bash
helm upgrade --install openwork-ee oci://ghcr.io/different-ai/charts/openwork-ee \
  --version REPLACE_OPENWORK_VERSION \
  --namespace openwork \
  --create-namespace \
  -f values.prod.yaml
```

Use the matching image tag in `values.prod.yaml`:

Create a values file for the target environment:

```yaml
image:
  tag: "REPLACE_OPENWORK_VERSION"

config:
  tenancy:
    # Default chart behavior is single-org for private/self-hosted installs.
    # Hosted OpenWork Cloud should set this to "multi_org" explicitly.
    mode: "single_org"
    singleOrgName: "OpenWork"
    singleOrgSlug: "default"
    ownerEmails: "admin@example.com"
    allowPublicSignup: "false"
    requireEmailVerification: "false"
  public:
    # Single public Den web origin. The chart renders this as DEN_BASE_URL and
    # den-api derives Better Auth, CORS/trusted origins, web-app hosts, API
    # defaults, and MCP resource defaults from it.
    webOrigin: "https://openwork.example.com"
    # Leave these blank unless you intentionally expose a split Den API origin
    # or need migration compatibility with an older topology.
    apiOrigin: ""
    mcpResourceUrl: ""
    mcpClaimNamespace: "https://openwork.example.com"
    desktopDenBaseUrl: ""
    corsOrigins: ""
    betterAuthTrustedOrigins: ""
    webAppHosts: ""
    bootstrapAdminEmails: "admin@example.com"
    # Self-hosted default: every organization gets install downloads.
    installLinksGatingEnabled: "false"
    authCallbackUrl: "https://openwork.example.com"
  githubConnector:
    appId: ""
    clientId: ""

secret:
  values:
    # Transitional/smoke TLS only: sslaccept=accept encrypts without certificate verification.
    # For production verification, use customCa plus sslmode=verify-full or verify-ca.
    databaseUrl: "mysql://openwork:REPLACE_ME@mysql.example.internal:3306/openwork_den?sslaccept=accept"
    betterAuthSecret: "REPLACE_WITH_AT_LEAST_32_CHARACTERS"
    denDbEncryptionKey: "REPLACE_WITH_AT_LEAST_32_CHARACTERS"
    emailFrom: "OpenWork <no-reply@example.com>"
    smtpHost: "smtp.example.com"
    smtpPort: "587"
    smtpUser: "openwork@example.com"
    smtpPass: "REPLACE_ME"
    smtpSecure: "false"
    githubConnectorAppClientSecret: ""
    githubConnectorAppPrivateKey: ""
    githubConnectorAppWebhookSecret: ""

ingress:
  enabled: true
  className: nginx
  web:
    host: openwork.example.com
  api:
    host: api.openwork.example.com
```

### Namespace

The chart sets `metadata.namespace` on every namespaced resource (Deployments,
Services, ConfigMap, Secret, Ingress, migration Job) from the `namespace` value,
which defaults to `openwork`:

~~~yaml
namespace: openwork
~~~

To use the Helm release namespace instead, set `namespace: ""` (or `--set namespace=`).

This keeps `helm template ... | kubectl apply -f -` pipelines from falling back
to the kubectl context namespace (e.g. `kube-system`). When installing with
Helm, keep `namespace` aligned with the release namespace:

```bash
helm upgrade --install openwork-ee oci://ghcr.io/different-ai/charts/openwork-ee \
  --namespace openwork \
  --create-namespace \
  -f values.prod.yaml
```

When applying rendered manifests directly, create the namespace first
(`kubectl create namespace openwork`) since Helm does not create it for you in
that flow.

### Namespace creation under ArgoCD

`createNamespace` (default `false`) controls whether the chart renders its own
`Namespace` object, as the earliest `pre-install,pre-upgrade` hook. It
defaults to `false` because it is unnecessary for the recommended `helm
install`/`helm upgrade --create-namespace` workflow (the CLI flag creates the
namespace itself, before this chart or any of its hooks ever render) and
actively dangerous under ArgoCD (below).

**This hook cannot help a first install into a not-yet-existing *release*
namespace** (the one passed via `helm install --namespace`): Helm creates its
own release-tracking record in that namespace before running any hook, so if
it does not already exist and `--create-namespace` was not passed, the
install fails immediately (`failed to create: namespaces "x" not found`)
before this or any pre-install hook ever runs — pre-provision that namespace
or pass `--create-namespace` regardless of this setting. Enable
`createNamespace` only when the Helm release namespace already exists (or is
a separate namespace altogether, e.g. a shared ops namespace) but this
chart's own `namespace` value points at a *different*, not-yet-existing
target namespace that this hook creates.

When enabled for that scenario as a genuine `helm install`/`helm upgrade` CLI
run, it is safe: the chart uses Helm's `lookup` function to detect an
already-existing namespace and skips rendering the hook entirely on every
upgrade after the first install.

**This safety check does not work under ArgoCD**, which is why the default is
`false` rather than relying on every consumer to override it. ArgoCD renders
charts with `helm template` in its repo-server, which has no live cluster
connection, so `lookup` always returns empty there — if `createNamespace` were
enabled, the Namespace hook would render on every single sync,
unconditionally. Helm and ArgoCD both document that a hook without an explicit
`hook-delete-policy` defaults to `before-hook-creation` (delete the previous
resource, then create a new one), and deleting a Namespace cascades to delete
everything inside it. Enabling `createNamespace` under ArgoCD would mean the
**entire release** — Deployments, Secrets, everything — gets torn down and
rebuilt on every sync.

Leave `createNamespace` at its default (`false`) for any ArgoCD `Application`
and instead let ArgoCD create the namespace itself:

```yaml
# Application values
createNamespace: false  # the default — shown for clarity, not required
```

```yaml
# Application spec
syncPolicy:
  syncOptions:
    - CreateNamespace=true
```

This is a native, non-hook, one-time ArgoCD operation with no delete-then-recreate
lifecycle, so the namespace (and everything in it) is created once and then
left alone by subsequent syncs.

The Namespace's hook-ness does not vary with `migrations.hook` (see
"Migrations" below): reclassifying the *same* resource between a hook and a
plain manifest across upgrades is unsafe in both directions, confirmed
against a live cluster — presenting an existing hook-created resource as an
ordinary one hard-fails the upgrade outright (`exists and cannot be imported
into the current release: invalid ownership metadata`, since hook-created
resources never receive Helm's release-ownership labels), and presenting an
existing ordinary resource as a hook for the first time deletes it before the
new hook's own annotations ever apply, cascading to everything inside —
confirmed by watching a canary resource get wiped out even though the new
hook render already carried `resource-policy: keep`.

Given that, this chart automatically detects and never disturbs a Namespace
that is already safe, and on direct Helm runs with live-cluster `lookup`
access safely migrates the one population that is not — without requiring
`createNamespace: true`, which matters because this same chart version also
flips that default from `true` to `false` (see above). For no-lookup renders
such as ArgoCD, that legacy plain-Namespace migration is not automatic: use
the explicit `migrateLegacyPlainNamespace=true` one-release path described
below before letting the chart omit the Namespace.

Using `lookup` to check the *live* object, this chart:

- Omits rendering entirely if the Namespace already carries either
  `helm.sh/hook` or `helm.sh/resource-policy: keep` — regardless of
  `createNamespace`. The first covers the common case of a release that
  predates this file, where the Namespace was already a hook under the old
  default (`migrations.hook: true`) and was never actually at risk (hook
  resources are never tracked by a release the way ordinary ones are, so
  re-rendering as a hook here would only reintroduce the very
  delete-then-create risk this logic exists to avoid — confirmed
  empirically, that reclassification is what deletes it); the second covers
  a Namespace an earlier release already migrated.
- Otherwise, if the Namespace exists, carries neither marker, and is already
  owned by *this* Helm release (its `meta.helm.sh/release-name` and
  `meta.helm.sh/release-namespace` annotations match this release, and it
  carries the `app.kubernetes.io/managed-by: Helm` label — the same
  ownership stamp Helm itself checks before agreeing to manage a
  pre-existing resource, confirmed empirically to be present on any
  chart-rendered resource and absent from one created via
  `--create-namespace` or plain `kubectl`): renders it as a plain, non-hook
  manifest that only adds the missing annotation, **regardless of
  `createNamespace`**, never reclassifying it, which Helm applies as an
  ordinary same-kind, already-owned in-place update. This is the actual
  legacy-migration case — a release that had `createNamespace: true` (the
  old default) and `migrations.hook: false` (the documented log-retention
  troubleshooting toggle), where the Namespace was an ordinary, Helm-tracked,
  non-hook resource with no protective annotation at all.
- Only creates a brand-new Namespace (as the earliest hook) when nothing
  exists live at all, and only then does it consult `createNamespace` —
  exactly the one decision that must default to `false` to keep ArgoCD (and
  any other GitOps flow with no live cluster access during rendering) from
  ever entering this hook path unintentionally.
- Otherwise (the Namespace exists but is owned by neither this release nor
  either marker — created entirely outside Helm, e.g. manually, via
  `--create-namespace`, or by ArgoCD's own `CreateNamespace=true`) leaves it
  alone when `createNamespace` is false (the correct outcome for a namespace
  this chart does not own), or attempts the fresh-hook-create path when
  `createNamespace` is mistakenly left/set `true`, which Helm's own
  ownership check then rejects with the same "cannot be imported" error
  above — a loud, non-destructive error prompting a config fix rather than
  silently adopting or destroying a namespace this release does not own.

`helm.sh/resource-policy: keep` itself states plainly (per Helm's docs) that
it "instructs Helm to skip deleting this resource when a helm operation
(such as `helm uninstall`, `helm upgrade` or `helm rollback`) would result in
its deletion" — checked against the live object's current annotations, not
the newly-rendered manifest. Once stamped, the *next* release finds the
marker already present and skips rendering the Namespace entirely from then
on too, exactly like the lookup-skip this file has always used for fresh
installs. For direct Helm upgrades, no operator action is required for this
migration; it happens automatically on the first upgrade to a chart version
carrying this fix, even if `createNamespace` is left at its new `false`
default. Under ArgoCD, do **not** rely on this lookup-based migration for an
existing release that previously used `migrations.hook: false`: make that
Namespace safe first (for example by setting
`migrateLegacyPlainNamespace=true` for one upgrade so the chart renders the
plain Namespace with both `helm.sh/resource-policy: keep` and ArgoCD
`Prune=false`, or by adding equivalent protection another way) before letting
the chart omit it. The direct Helm path was verified with live
install/upgrade cycles against a real cluster, checking object identity (UID)
and a canary resource's survival: an existing, unprotected Namespace upgraded
to this chart version with `createNamespace` deliberately left unset (so it
evaluates to the new `false` default) survives, unchanged in identity, newly
stamped with `resource-policy: keep`.

### Upgrade note: public URL values

Current chart versions make `config.public.webOrigin` the primary public URL.
It renders as `DEN_BASE_URL`, and Den derives these values from it unless you
set explicit compatibility overrides:

- `BETTER_AUTH_URL`
- `CORS_ORIGINS`
- `DEN_BETTER_AUTH_TRUSTED_ORIGINS`
- `DEN_WEB_APP_HOSTS`
- `DEN_API_PUBLIC_URL`
- `DEN_MCP_RESOURCE_URL`

When upgrading an existing release, inspect your values file for the older
split-origin keys under `config.public`. If your deployment is single-origin,
remove `apiOrigin`, `mcpResourceUrl`, `desktopDenBaseUrl`, `corsOrigins`,
`betterAuthTrustedOrigins`, and `webAppHosts` or set them to `""` so Den can
derive them from `webOrigin`. Keep `apiOrigin`/`mcpResourceUrl` only when you
intentionally expose a separate API origin for install-link exchange or external
MCP clients.

For private GHCR packages, authenticate before installing:

```bash
helm registry login ghcr.io
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<github-token>
```

Then add:

```yaml
imagePullSecrets:
  - name: ghcr-pull-secret
```

For local development from a repository checkout, render or install directly:

```bash
helm template openwork-ee ./packaging/helm/openwork-ee -f values.prod.yaml
helm upgrade --install openwork-ee ./packaging/helm/openwork-ee \
  --namespace openwork \
  --create-namespace \
  -f values.prod.yaml
```

### Automations rollout

The Helm chart advertises Automations as unavailable by default for self-hosted
and customer-managed deployments. Availability and server shutdown are
separate so a Den upgrade cannot remove routes beneath an older published
Desktop:

| `automationsEnabled` | `automationsRuntimeEnabled` | Behavior |
| --- | --- | --- |
| `"false"` | `"true"` | New Desktops hide Automations; legacy routes and scheduling remain available during the upgrade window. |
| `"false"` | `"false"` | Automations are hard-disabled: routes, MCP resources, and scheduler startup are omitted. |
| `"true"` | `"true"` | Automations are available and execute normally. |
| `"true"` | `"false"` | The runtime shutdown wins and Desktop receives `automationsEnabled: false`. |

Set both values explicitly when the deployment is ready to run Automations:

```yaml
config:
  public:
    automationsEnabled: "true"
    automationsRuntimeEnabled: "true"
```

These render `DEN_AUTOMATIONS_ENABLED=true` and
`DEN_AUTOMATIONS_RUNTIME_ENABLED=true` for Den. An entirely unconfigured Den
keeps availability fail-closed while preserving the legacy runtime. When using
raw environment variables, an explicit `DEN_AUTOMATIONS_ENABLED` value also
becomes the runtime default: `false` is therefore a complete shutdown unless
`DEN_AUTOMATIONS_RUNTIME_ENABLED=true` explicitly selects mixed-version
compatibility. The chart always renders both values to make that choice
unambiguous. Hosted OpenWork Cloud explicitly enables availability.

Desktop v0.18.35 and newer consume the value from `/v1/me/desktop-config`, hide
the Automation surface, and do not register a runner unless the value is
explicitly true. Older clients predate that contract, so the runtime flag must
remain true while they are in use even when availability is false.

For an existing deployment, stage the upgrade so independently released Den
and Desktop versions never observe an unintended flag state:

1. Keep `config.public.automationsRuntimeEnabled: "true"` while any connected
   Desktop is older than v0.18.35.
2. Upgrade Den. Legacy Desktops retain their existing routes and scheduling;
   compatible Desktops honor `automationsEnabled` from desktop config.
3. Roll out Desktop v0.18.35 or newer to the whole deployment.
4. To keep Automations, set both values to true. To disable them, set both
   values to false only after the Desktop rollout is complete.

New installations with no legacy Desktop clients can hard-disable Automations
immediately by setting both values to false.

### Dashboards rollout

The organization-managed Dashboard is unavailable by default. Enable it for a
self-hosted or customer-managed deployment with:

```yaml
config:
  public:
    dashboardsEnabled: "true"
```

The chart renders this value as `DEN_DASHBOARDS_ENABLED`. Raw environment-based
deployments can set the same variable directly. Hosted environments use that
same flag, so Dashboard availability does not depend on a per-device preference.
Desktop reads `dashboardEnabled` from `/v1/me/desktop-config` and hides both the
sidebar entry and route unless the server explicitly returns `true`.

### OpenWork Web rollout

OpenWork Web is unavailable by default for self-hosted and customer-managed
deployments. OpenWork Cloud enables it in its deployment values with:

```yaml
config:
  public:
    openworkWebEnabled: "true"
```

The chart renders this value as `DEN_OPENWORK_WEB_ENABLED`. A raw environment
deployment can set the same variable directly. Missing, blank, false, or an
unrecognized value fails closed: Den omits Web from its advertised
capabilities, the sidebar and Billing offer stay hidden, and Web billing routes
return the deployment-unavailable response. Availability is deployment-wide;
it does not depend on organization mode, Stripe-variable presence, or mutable
organization metadata.

Enabling the flag advertises the hosted product. The deployment must also
configure `STRIPE_SECRET_KEY` and `STRIPE_OPENWORK_WEB_PRICE_ID` before the
purchase action becomes available. This separate billing-readiness check keeps
a partially configured hosted rollout visible but non-purchasable instead of
mistaking secrets for an availability signal.

Provider-specific starter guides:

- AWS EKS:
  [guide](../../../docs/aws-eks-helm.md),
  [`examples/values.aws-load-balancer.yaml`](examples/values.aws-load-balancer.yaml),
  [`examples/values.aws-load-balancer-http-smoke.yaml`](examples/values.aws-load-balancer-http-smoke.yaml).
  The recommended first AWS path is EKS Auto Mode plus `LoadBalancer` Services,
  which provisions AWS Network Load Balancers without installing an ingress
  controller.
- Azure AKS:
  [guide](../../../docs/azure-aks-helm.md),
  [`examples/values.azure-ingress.yaml`](examples/values.azure-ingress.yaml).
  The recommended first Azure path is VNet-first AKS application routing plus
  Azure Database for MySQL Flexible Server private access, with
  `ingress.enabled=true`.
- Google Cloud GKE:
  [guide](../../../docs/gcp-gke-helm.md),
  [`examples/values.gcp-ingress.yaml`](examples/values.gcp-ingress.yaml).
  The recommended first GCP path is GKE Ingress with a reserved global IP,
  Google-managed certificate, and BackendConfig health checks.

`ingress.enabled=true` only emits Kubernetes `Ingress` resources; it does not
install an ingress controller. Use it only when the cluster already has a
compatible provider ingress controller.

Published self-host planning pages:

- [Private network deployment](../../../packages/docs/start-here/private-network-deployment.mdx)
- [Air-gapped deployment](../../../packages/docs/start-here/air-gapped-deployment.mdx)
- [Installer delivery](../../../packages/docs/start-here/installer-delivery.mdx)
- [Certificate trust and proxies](../../../packages/docs/start-here/certificate-trust-and-proxies.mdx)

## Secrets

The deployment declares how it manages secrets with a single key:

```yaml
secret:
  secretsMode: inline # inline | existingSecret | externalSecrets
```

- `inline` (default): the chart renders an Opaque Secret from `secret.values`.
  Local evaluation only — the values live wherever the values file lives, so
  never commit real credentials.
- `existingSecret`: workloads consume a pre-created Secret named by
  `secret.existingSecret` (requires `secret.create: false`); the chart renders
  no secret resource.
- `externalSecrets`: the chart renders an
  [External Secrets Operator](https://external-secrets.io/) `ExternalSecret`
  that materializes the workload Secret from an external provider — the
  GitOps/ArgoCD-safe path, where git holds only store references and remote
  key paths (requires `secret.create: false`).

Any `secret.keys` override applies in every mode, since all three resolve the
workload Secret through the same names. The mode combinations are enforced at
render time: an unknown `secretsMode`, a missing `secret.existingSecret` in
`existingSecret` mode, `secret.existingSecret` set in any other mode, and
`secret.create: true` outside `inline` mode all fail the render.

### existingSecret

```yaml
secret:
  secretsMode: existingSecret
  create: false
  existingSecret: openwork-ee-secrets
```

The existing Secret must be created in the `namespace` where the chart deploys
(default `openwork`) before the workloads start, and must contain the keys
listed under `secret.keys`, especially:

- `DATABASE_URL`
- `BETTER_AUTH_SECRET`
- `DEN_DB_ENCRYPTION_KEY`

### externalSecrets (GitOps / ArgoCD)

For GitOps flows (ArgoCD runs `helm template`, so anything in values lands in
git and in rendered manifests), use ESO mode. The chart renders an
`ExternalSecret` that materializes the same-named workload Secret from your
provider in-cluster:

The chart renders `spec.data` — the oldest stable ESO shape, unchanged since
`external-secrets.io/v1beta1` — pulling keys from `<pathPrefix>/<KEY_NAME>` in
the provider by default (`externalSecrets.keyLayout: perKey`). Only the three
boot-critical keys (`DATABASE_URL`, `BETTER_AUTH_SECRET`,
`DEN_DB_ENCRYPTION_KEY`) are rendered by default; add more by name via
`optionalKeys`:

```yaml
secret:
  secretsMode: externalSecrets
  create: false
externalSecrets:
  secretStoreRef:
    # References an existing (Cluster)SecretStore; for AWS Secrets Manager the
    # store itself carries spec.provider.aws (region, auth), the chart only
    # points at it by name.
    name: external-secrets
    kind: ClusterSecretStore
  refreshInterval: 5m
  # The three boot-critical keys must exist under this trunk, e.g.
  # eks/openwork/prod/den/DATABASE_URL.
  pathPrefix: "eks/openwork/prod/den"
  # Additional keys to pull, by secret.keys.* name. Only listed keys are
  # rendered, so keys you do not list need not exist in the provider.
  optionalKeys:
    - databaseRedisUrl
    - emailFrom
    - smtpHost
    - smtpPort
    - smtpUser
    - smtpPass
    - smtpSecure
```

If your provider instead stores one combined secret per service (a single
entry holding a JSON object of key/value pairs, e.g. an AWS Secrets Manager
entry named `eks/<project>/<env>/<service>`) rather than one entry per key, set
`externalSecrets.keyLayout: singleSecret`. `pathPrefix` then names that single
secret directly, and each key is read from its same-named JSON property inside
it instead of from `<pathPrefix>/<KEY_NAME>`:

```yaml
externalSecrets:
  pathPrefix: "eks/openwork/prod/den"
  keyLayout: singleSecret
```

With `keyLayout: singleSecret`, the provider secret at `eks/openwork/prod/den`
must be a JSON object such as
`{"DATABASE_URL": "...", "BETTER_AUTH_SECRET": "...", "DEN_DB_ENCRYPTION_KEY": "..."}`,
plus any `optionalKeys` properties you list.

The three required keys must exist in your provider — where depends on
`keyLayout`, as above — and a missing one fails the ExternalSecret loudly.
ESO's `remoteRef` has no "skip-if-missing" field, so optional keys are opt-in:
any `secret.keys.*` name you list under `optionalKeys` must exist in the
provider, and keys you omit do not land in the Secret. Omitted keys are simply
absent from the workload environment, so check each consumer before omitting
one. Two illustrative cases: `DAYTONA_API_KEY` is *required* when
`config.provisioner.mode` is `daytona` — Den API rejects startup without it, so
omitting it there breaks boot, whereas it is safe to omit under the default
`stub` provisioner; and omitted `SMTP_PORT`/`SMTP_SECURE` fall back to the
application's own defaults (`587` / `false`) whenever they are absent,
regardless of whether the Secret carries them. `optionalKeys` entries are
`secret.keys` **property names** (camelCase, e.g. `smtpPass`); the target
Secret key uses the corresponding **value** (`SMTP_PASS` by default,
overridable via `secret.keys.smtpPass`). So list `smtpPass` here, and depending
on `keyLayout`:

- `perKey`: ensure `eks/.../SMTP_PASS` (or your overridden value) exists in the
  provider as its own entry.
- `singleSecret`: ensure the single combined secret at `pathPrefix` has a
  `SMTP_PASS` JSON property.

Either way the target Secret key is `SMTP_PASS`.
`target.deletionPolicy` defaults to `Retain`, so uninstalling the release keeps
the materialized Secret. ESO must be installed on the destination cluster with
a `SecretStore`/`ClusterSecretStore`; the chart selects
`external-secrets.io/v1` or `v1beta1` from cluster capabilities and fails
loudly at sync time if the CRDs are missing.


Set optional `DATABASE_REDIS_URL` to enable Den API Redis-backed session and query caching. Set `DAYTONA_API_KEY` when `config.provisioner.mode` is `daytona`. Set `POLAR_ACCESS_TOKEN` when Polar feature gating is enabled. Set `OPENROUTER_MANAGEMENT_API_KEY` when enabling OpenWork Models management.

Redis cache examples:

```yaml
secret:
  values:
    databaseRedisUrl: "rediss://redis-master.openwork.svc.cluster.local:6379"
```

Prefer `rediss://`. For hosting platforms that only provide a private internal
`redis://` URL, such as Render internal Redis, explicitly acknowledge the trust
boundary with `redis.allowInsecureInternal=true`. Use this only when the Redis
endpoint is non-public and reachable only from trusted services in the private
network.

```yaml
redis:
  allowInsecureInternal: true
secret:
  values:
    databaseRedisUrl: "redis://red-...:6379"
```

## Custom CA certificates

For higher-level planning across desktop, sidecar, Den, and MySQL trust
surfaces, see the published
[Certificate trust and proxies](../../../packages/docs/start-here/certificate-trust-and-proxies.mdx)
page. This section remains the authoritative chart values reference.

Use `customCa` when OpenWork must trust a private certificate authority for
strict TLS verification, such as a MySQL endpoint signed by an internal or cloud
private CA. The chart does not accept PEM material in values and does not create
the CA resource for you; create the Kubernetes Secret or ConfigMap in the
release namespace before running `helm install` or `helm upgrade`.

Secret example:

```bash
kubectl create secret generic openwork-custom-ca \
  --namespace openwork \
  --from-file=ca.crt=./corp-root-ca.pem
```

```yaml
customCa:
  enabled: true
  existingSecret: openwork-custom-ca
  existingConfigMap: ""
  key: ca.crt
```

ConfigMap example:

```bash
kubectl create configmap openwork-custom-ca \
  --namespace openwork \
  --from-file=ca.crt=./corp-root-ca.pem
```

```yaml
customCa:
  enabled: true
  existingSecret: ""
  existingConfigMap: openwork-custom-ca
  key: ca.crt
```

When enabled, set exactly one of `existingSecret` or `existingConfigMap`, and set
`key` to the data key containing the CA bundle. The chart mounts only that key as
`/etc/openwork/custom-ca/ca-bundle.pem` and sets `NODE_EXTRA_CA_CERTS` to that
file for `den-api`, `den-web`, enabled `inference`, and the migration Job. Do
not also set `denApi.env.NODE_EXTRA_CA_CERTS`, `denWeb.env.NODE_EXTRA_CA_CERTS`,
or `inference.env.NODE_EXTRA_CA_CERTS`; Helm rejects those conflicts while
`customCa.enabled=true`.

For strict MySQL TLS verification, pair the mounted CA with a verifying
`DATABASE_URL`, for example:

```yaml
secret:
  values:
    databaseUrl: "mysql://openwork:REPLACE_DB_PASSWORD@mysql.example.internal:3306/openwork_den?sslmode=verify-full"
```

`sslmode=verify-ca`, `sslmode=verify-full`, and `sslaccept=strict` enable strict
certificate verification. `sslaccept=accept` keeps TLS enabled but does not
verify the certificate chain, so use it only for smoke tests or while preparing
the CA bundle.

The custom CA is release-wide for Node.js processes in this chart. Treat it as a
global trust decision for outbound TLS from those workloads, and include only CA
roots your OpenWork deployment should trust. On CA rotation, update the existing
Secret or ConfigMap and restart the running workloads so Node reloads the CA
file, for example:

```bash
kubectl rollout restart deployment/openwork-ee-den-api --namespace openwork
kubectl rollout restart deployment/openwork-ee-den-web --namespace openwork
kubectl rollout restart deployment/openwork-ee-inference --namespace openwork
```

The next migration hook Job will mount the current CA data; rerun a failed
upgrade after the CA resource is corrected.

## Observability

The chart exposes first-class runtime observability settings for `den-api` and
`den-web` only. `observability.backend` defaults to `none`; set it to `otel` or
`sentry` to enable the matching runtime environment. The chart injects distinct
`OTEL_SERVICE_NAME` values directly into each Deployment, so the shared
ConfigMap is not used for service identity or auth-like observability values.

OpenTelemetry uses OTLP over `http/protobuf`, with a shared endpoint and
optional per-signal endpoint overrides. Per-signal exporters default to `otlp`,
and trace sampling defaults to the standard parent-based always-on sampler.

### OpenTelemetry quick start

Before starting, you need:

- An OpenTelemetry Collector or vendor endpoint reachable from the Kubernetes
  cluster over OTLP HTTP. Port `4318` is the usual Collector port.
- The endpoint's authentication token or headers, if it requires
  authentication.
- `kubectl` and Helm configured for the target cluster.

The chart configures telemetry export from OpenWork; it does not install an
OpenTelemetry Collector. For an in-cluster Collector, use its Kubernetes DNS
name, for example
`http://otel-collector.observability.svc.cluster.local:4318`. Do not use
`localhost`, because that would refer to the OpenWork container itself.

First create the namespace used by this example:

```bash
kubectl create namespace openwork
```

If the Collector does not require authentication, skip the Secret and leave
`observability.otel.headers.existingSecret` empty.

If it requires a bearer token, create the header Secret in the **same
namespace as OpenWork**:

```bash
kubectl create secret generic openwork-otel-headers \
  --namespace openwork \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS='Authorization=Bearer <token>'
```

Replace `<token>` with the real token. Keep the single quotes so your shell
passes the complete header as one value. To update an existing Secret without
deleting it first, use:

```bash
kubectl create secret generic openwork-otel-headers \
  --namespace openwork \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS='Authorization=Bearer <token>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Multiple OTLP headers use the standard comma-separated `key=value` format:

```bash
kubectl create secret generic openwork-otel-headers \
  --namespace openwork \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS='Authorization=Bearer <token>,x-scope-orgid=<tenant>'
```

Do not put tokens directly in a values file. Kubernetes Secrets are not
encrypted by default unless your cluster enables encryption at rest, so use
your organization's external-secret or secret-management system in production
when available.

Create `values-observability.yaml`:

```yaml
observability:
  backend: otel
  serviceNames:
    denApi: openwork-den-api
    denWeb: openwork-den-web
  otel:
    endpoint: "http://otel-collector.observability.svc.cluster.local:4318"
    tracesEndpoint: ""
    metricsEndpoint: ""
    logsEndpoint: ""
    exporters:
      traces: otlp
      metrics: otlp
      logs: otlp
    tracesSampler: parentbased_always_on
    tracesSamplerArg: ""
    headers:
      existingSecret: openwork-otel-headers
      key: OTEL_EXPORTER_OTLP_HEADERS
```

For a Collector without authentication, use:

```yaml
    headers:
      existingSecret: ""
      key: OTEL_EXPORTER_OTLP_HEADERS
```

Install or upgrade OpenWork with the values file:

```bash
helm upgrade --install openwork-ee ./packaging/helm/openwork-ee \
  --namespace openwork \
  --create-namespace \
  --values values-observability.yaml
```

`observability.otel.headers.existingSecret` must name an existing Kubernetes
Secret. Its key is exposed as `OTEL_EXPORTER_OTLP_HEADERS` only on `den-api` and
`den-web`; it is not added to inference pods or migration Jobs.

### Verify the OpenTelemetry setup

The commands below assume the Helm release is named `openwork-ee`. If you use a
different release name, run `kubectl get deployments,services --namespace
openwork` to find the generated resource names.

Confirm that the workloads are ready:

```bash
kubectl get pods --namespace openwork
kubectl rollout status deployment/openwork-ee-den-api --namespace openwork
kubectl rollout status deployment/openwork-ee-den-web --namespace openwork
```

Inspect the rendered environment references without printing the Secret's
value:

```bash
kubectl describe deployment/openwork-ee-den-api --namespace openwork
kubectl describe deployment/openwork-ee-den-web --namespace openwork
```

Look for `DEN_OBSERVABILITY_BACKEND=otel`, distinct `OTEL_SERVICE_NAME` values,
the OTLP endpoint, and an `OTEL_EXPORTER_OTLP_HEADERS` reference to
`openwork-otel-headers`.

Generate a request that crosses both services. Keep this port-forward running:

```bash
kubectl port-forward service/openwork-ee-den-web 3005:3005 --namespace openwork
```

In another terminal:

```bash
curl --fail --silent --show-error \
  http://127.0.0.1:3005/api/den/openapi.json >/dev/null
```

Your observability backend should show `openwork-den-web` and
`openwork-den-api`, with one connected trace for the request. Logs from both
services carry trace and span IDs. Den API also exports Hono request-duration
and active-request metrics.

### Endpoint and troubleshooting notes

- `observability.otel.endpoint` is a base endpoint. OpenWork appends
  `/v1/traces`, `/v1/metrics`, and `/v1/logs`.
- Signal-specific endpoints are used exactly as written. Include the full
  signal path, such as `https://collector.example.com/v1/traces`.
- Only OTLP HTTP/protobuf is supported. Port `4317` is normally OTLP gRPC and
  will not work; use the HTTP receiver, usually port `4318`.
- The Secret must be in the OpenWork release namespace, and its key must match
  `observability.otel.headers.key` exactly.
- A `401` or `403` exporter error usually means the token or header syntax is
  wrong. A connection error usually means the endpoint is not reachable from
  the pod or a NetworkPolicy blocks it.
- After changing an externally managed Secret, restart the deployments if your
  secret controller does not trigger a rollout:

  ```bash
  kubectl rollout restart deployment/openwork-ee-den-api --namespace openwork
  kubectl rollout restart deployment/openwork-ee-den-web --namespace openwork
  ```
- For lower production trace volume, use
  `tracesSampler: parentbased_traceidratio` with `tracesSamplerArg: "0.1"` to
  sample approximately ten percent of root traces.

For Sentry runtime capture, configure the DSN directly or through an existing
Secret. Helm runtime pods intentionally do not receive `SENTRY_AUTH_TOKEN`,
`SENTRY_ORG`, `SENTRY_PROJECT`, or `SENTRY_URL`; those are build-time source-map
upload settings, not runtime settings.

```yaml
observability:
  backend: sentry
  sentry:
    dsnSecret:
      existingSecret: openwork-sentry-runtime
      key: SENTRY_DSN
    tracesSampleRate: "0.01"
    environment: production
    release: "2026.07.11"
```

Sentry Logs default to warning-and-error only through `SENTRY_LOG_LEVEL=warn`.
Set `SENTRY_LOG_LEVEL=info` only during short debugging windows if you need
successful request logs in Sentry; stdout JSON logs remain available either way.

Sentry source-map upload is build-time behavior. Helm configures runtime pods
after images already exist, so it cannot retroactively upload source maps for
Vercel or CI builds. Set `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT`,
and `SENTRY_URL` in the build environment that creates the image (for example,
Vercel project build environment variables), not in Helm values or the chart
ConfigMap. The generic published images cannot upload source maps after they
are built; build your own image with CI/BuildKit source-map secrets when you
need uploaded artifacts. `packaging/docker/Dockerfile.den-web` accepts optional
BuildKit secret IDs `sentry_auth_token`, `sentry_org`, `sentry_project`,
`sentry_url`, `sentry_release`, and `sentry_dist`; the EE image publish workflow
wires these IDs from GitHub Secrets when present.

## GitHub Connector

The GitHub repository connector uses a GitHub App. It is separate from GitHub
OAuth social sign-in. Follow the full setup guide in
[`packages/docs/start-here/github-connector-helm.mdx`](../../../packages/docs/start-here/github-connector-helm.mdx).

Use these public URLs when creating the GitHub App:

- Setup URL: `https://openwork.example.com/dashboard/integrations/github`
- Webhook URL: `https://api.openwork.example.com/v1/webhooks/connectors/github`

Then set the chart values:

```yaml
config:
  githubConnector:
    appId: "123456"
    clientId: "Iv1.example"

secret:
  values:
    githubConnectorAppClientSecret: "github-app-client-secret-if-used"
    githubConnectorAppPrivateKey: |-
      -----BEGIN PRIVATE KEY-----
      ...
      -----END PRIVATE KEY-----
    githubConnectorAppWebhookSecret: "replace-with-the-github-webhook-secret"
```

The chart exposes these to Den API as:

- `GITHUB_CONNECTOR_APP_ID`
- `GITHUB_CONNECTOR_APP_CLIENT_ID`
- `GITHUB_CONNECTOR_APP_CLIENT_SECRET`
- `GITHUB_CONNECTOR_APP_PRIVATE_KEY`
- `GITHUB_CONNECTOR_APP_WEBHOOK_SECRET`

If `secret.create=false`, add the three secret-backed keys to the existing
Secret referenced by `secret.existingSecret`. The app ID and client ID come from
the chart ConfigMap.

## Transactional Email

Den API can send transactional email through SMTP. Configure the SMTP values in
the chart Secret:

```yaml
secret:
  values:
    emailFrom: "OpenWork <no-reply@example.com>"
    smtpHost: "smtp.example.com"
    smtpPort: "587"
    smtpUser: "openwork@example.com"
    smtpPass: "REPLACE_ME"
    smtpSecure: "false"
```

These values are exposed to Den API as:

- `EMAIL_FROM`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USER`
- `SMTP_PASS`
- `SMTP_SECURE`

If `secret.create=false`, add those keys to the existing Secret referenced by
`secret.existingSecret`. SMTP delivery requires both `EMAIL_FROM` and
`SMTP_HOST`; leave `smtpHost` blank only when SMTP-backed transactional email
should be disabled.

## Tenancy Mode

The chart defaults to a private single-org deployment:

```yaml
config:
  tenancy:
    mode: "single_org"
    singleOrgName: "OpenWork"
    singleOrgSlug: "default"
    ownerEmails: "admin@example.com"
    allowPublicSignup: "false"
    requireEmailVerification: "false"
```

These values are exposed to both `den-api` and `den-web` as:

- `DEN_ORG_MODE`
- `DEN_SINGLE_ORG_NAME`
- `DEN_SINGLE_ORG_SLUG`
- `DEN_SINGLE_ORG_OWNER_EMAILS`
- `DEN_SINGLE_ORG_ALLOW_PUBLIC_SIGNUP`
- `DEN_REQUIRE_EMAIL_VERIFICATION`

In the implemented target state, blank or unset `DEN_ORG_MODE` is treated as `single_org`. The Helm chart sets it explicitly to make rendered manifests clear. Hosted or cloud-style multi-organization deployments should set:

```yaml
config:
  tenancy:
    mode: "multi_org"
    requireEmailVerification: "true"
```

`config.tenancy.ownerEmails` controls who can claim ownership of the singleton deployment organization. `config.public.bootstrapAdminEmails` is separate: it seeds platform/admin allowlist access and does not by itself make a user the singleton organization owner.

## Initial Organization Setup

For self-hosted installs, configure the singleton organization before the first
user signs in:

```yaml
config:
  tenancy:
    mode: "single_org"
    singleOrgName: "Acme"
    singleOrgSlug: "acme"
    ownerEmails: "admin@acme.com"
    requireEmailVerification: "false"
  public:
    bootstrapAdminEmails: "admin@acme.com"
```

For releases that include initial-administrator bootstrap, inject the
release-documented one-time setup secret through the chart's Secret integration.
Do not put the setup code in Helm values, a ConfigMap, source control, logs, or a
PR. After the release is installed and the web host is reachable, open `/setup`,
enter an email configured in `config.tenancy.ownerEmails`, and verify it with the
one-time operator code. Den then creates the Better Auth account, creates or
claims the singleton organization identified by `singleOrgName` and
`singleOrgSlug`, grants owner and configured platform-admin access, and consumes
the setup claim. The code cannot be reused and public signup remains disabled.

Configuring `ownerEmails` or `bootstrapAdminEmails` does not create an account or
password. `ownerEmails` controls singleton-organization ownership;
`bootstrapAdminEmails` controls platform-admin allowlist access. Configure the
initial administrator in both lists when that person needs both roles.

Chart versions without the `/setup` route do not support this private bootstrap
flow. Upgrade to a release that includes initial-administrator bootstrap before
attempting first-user setup; entering the configured email on the normal sign-in
page cannot create the account and no default administrator password exists.

Later users are attached to the same singleton organization. They do not see an
organization creation step, and attempts to create another organization return a
single-org-mode error. If no eligible initial-administrator email is configured,
the private setup flow remains unavailable; it never falls back to allowing an
arbitrary first visitor to claim ownership.

For most production installs, use this first owner account as the break-glass
setup path, then configure SAML/OIDC SSO and SCIM from the organization
settings. Keep `bootstrapAdminEmails` aligned only if that same person should
also have platform/admin allowlist access; it is not a replacement for
`ownerEmails`.

After SAML/OIDC SSO is configured on the singleton organization, the auth
experience becomes SSO-only: root sign-in and sign-up show one "Continue with
SSO" action, other sign-in/sign-up entry points redirect there, and raw
email/password sign-in or sign-up requests are rejected by Den API.

## Internal Service URLs

By default, the chart wires internal services through Kubernetes DNS:

- `DEN_API_BASE=http://<release>-openwork-ee-den-api:8788`
- `DEN_AUTH_FALLBACK_BASE=http://<release>-openwork-ee-den-api:8788`
- `INFERENCE_PROXY_BASE_URL=http://<release>-openwork-ee-inference:8791` when `inference.enabled=true`

Override `config.internal.*` only when routing through a mesh, gateway, or external service.

## Den API Node Options

Set `config.denApiNodeOptions` to pass Node.js runtime flags to `den-api` through
`NODE_OPTIONS` when the container starts. The configured value is stored in the
chart ConfigMap as `DEN_API_NODE_OPTIONS` and defaults to an empty string.
Existing values files that set `denApi.env.NODE_OPTIONS` remain supported and
take precedence, so upgrading does not require changing that configuration.

```yaml
config:
  denApiNodeOptions: "--max-old-space-size=4096"
```

`--use-openssl-ca` only changes how Node reads operating-system trust. It does
not create or mount a private CA bundle into the container; use `customCa` for
that.

## Service Exposure

Each service supports Kubernetes Service metadata and load balancer settings:

```yaml
denWeb:
  service:
    type: LoadBalancer
    port: 443
    loadBalancerClass: eks.amazonaws.com/nlb
    loadBalancerSourceRanges:
      - 203.0.113.0/24
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
      service.beta.kubernetes.io/aws-load-balancer-ssl-cert: arn:aws:acm:...
      service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
```

The same shape is available under `denApi.service` and `inference.service`.
`ingress.enabled=true` only emits Kubernetes `Ingress` resources; it does not
install an ingress controller.

## Config Rollouts

Den API, Den Web, and inference pods include checksums for the chart-managed
ConfigMap and Secret. Helm upgrades that change runtime config or secrets roll
the pods automatically so environment variables such as public origins, CORS
origins, and database URLs are refreshed.

## Isolated Networks

Use the published [Air-gapped deployment](../../../packages/docs/start-here/air-gapped-deployment.mdx)
and [Outbound network access](../../../packages/docs/start-here/outbound-network-access.mdx)
pages for customer-facing isolation and allowlist planning. The values below are
the chart-level controls.

The chart disables external password breach screening by default so isolated self-hosted installs do not depend on the Have I Been Pwned Pwned Passwords range API. If your deployment has approved outbound access and you want password creation and reset to reject known-compromised passwords through that service, enable it:

```yaml
config:
  auth:
    passwordBreachScreeningEnabled: "true"
```

Local sign-in lockout protections stay enabled either way.

Den API also protects External MCP connection URLs with an SSRF guard. On a
hosted multi-tenant deployment, someone who can add an MCP connection could
otherwise make Den fetch localhost, private-network services, or cloud metadata
addresses from Den's network position.

If a legitimate internal MCP server is blocked in an isolated private-network
deployment, the diagnostic code is `MCP_URL_BLOCKED` and the operator-facing
message is: "Use a public HTTPS MCP URL or change the deployment's
private-network policy through security review."

To allow private-address MCP servers for Den API, enable:

```yaml
config:
  public:
    allowPrivateMcpUrls: "1"
```

This disables SSRF protection for external MCP connection URLs. Enable it only
on a deployment where Den's network position and the set of people who can add
MCP connections are both trusted.

## Migrations

The migration Job runs as a Helm `pre-install,pre-upgrade` hook by default:

```yaml
migrations:
  enabled: true
  hook: true
  hookDeletePolicy: before-hook-creation,hook-succeeded,hook-failed
  command:
    - node
  args:
    - /app/ee/packages/den-db/dist/scripts/bootstrap.js
```

The default hook executes the precompiled Den DB bootstrap runner already built into the Den API image. On a completely empty database it applies the build-time current-schema SQL snapshot, records the committed migrations as the baseline, then runs pending migrations with Drizzle ORM. On an existing schema without a Drizzle ledger, it records the baseline before migrating.

`hookDeletePolicy` keeps `hook-failed` alongside the defaults: a Job's pod
template is immutable, so `before-hook-creation` gives each hook run a clean
slate by deleting the previous instance first, but a **failed** run without
`hook-failed` used to sit around until the *next* sync's `before-hook-creation`
delete tried to clear it — and if that delete raced ArgoCD's own automated-sync
retry timing, the Job (and, via ArgoCD's `hook-finalizer`, the namespace behind
it) could get stuck `Terminating` indefinitely. `hook-failed` deletes it
immediately instead, well clear of the next sync attempt. The migration RBAC
(`ServiceAccount`/`Role`/`RoleBinding`) and the `ExternalSecret` hooks also
carry `before-hook-creation` explicitly — Helm and ArgoCD both document that
this is the default applied to any hook without an explicit
`hook-delete-policy` anyway, so leaving it off would not change behavior, only
leave it undocumented. It is tolerable for these leaf, non-cascading resources
(no finalizers, so the delete completes essentially instantly, and the
ExternalSecret's `target.deletionPolicy: Retain` protects the materialized
Secret regardless). It is *not* tolerable for the Namespace hook, because
deleting a Namespace cascades to everything inside it — see "Namespace
creation under ArgoCD" above for why that one needs a different fix entirely
(`createNamespace: false` plus ArgoCD's own `syncOptions: [CreateNamespace=true]`),
not an annotation choice.

`migrations.hook` only ever affects the ExternalSecret, migration RBAC, and
migration Job above — it never affects the Namespace (see "Namespace creation
under ArgoCD"), which is always a hook whenever `createNamespace` is true,
independent of this value.

For retained-log troubleshooting, temporarily disable hook behavior and reduce
retries:

```yaml
migrations:
  enabled: true
  hook: false
  backoffLimit: 0
```

The hook Job currently renders `DATABASE_URL` and `DEN_DB_ENCRYPTION_KEY` into
the Job environment when `secret.create=true`, because pre-install hooks run
before normal chart resources. Avoid sharing `kubectl describe job` output
without redacting secrets.

## Install links

The migration Job creates the `install_link` and `desktop_connect_grant` tables
automatically when `migrations.enabled=true`. Hosted deployments that enable
install-link gating must opt organizations in through `/admin`; self-hosted
deployments default to enabled. See the
[operator guide](../../../docs/org-install-links.md) and the published
[Installer delivery](../../../packages/docs/start-here/installer-delivery.mdx)
page.

Optional installer artifact values:

```yaml
config:
  public:
    installerReleaseTag: "v0.17.9"
    installerReleaseRepo: "different-ai/openwork"

installerArtifacts:
  enabled: true
  existingClaim: openwork-desktop-artifacts
  mountPath: /var/lib/openwork/installer-artifacts
```

Use either `installerArtifacts.existingClaim` or `installerArtifacts.hostPath`,
not both.

### Guided desktop setup

The organization download page hands the normal OpenWork app its Den
configuration in an explicit second step. The default is a short-lived,
single-use HTTPS exchange and needs no key configuration:

```yaml
config:
  public:
    connectLinkMode: exchange
```

Den validates the install token and then either:

- streams the standard installer already mounted at
  `installerArtifacts.mountPath`; or
- redirects the browser directly to the exact configured GitHub release asset.

Den does not download, cache, wrap, or ZIP GitHub artifacts. The organization
setup stays in the **Open OpenWork** deep-link step after installation.

For an optional signed handoff, explicitly select signed mode and configure a
dedicated Ed25519 key whose public key is already trusted by the desktop build:

```yaml
config:
  public:
    connectLinkMode: signed
    connectLinkKeyId: "owc-2026-07"

secret:
  values:
    connectLinkPrivateKey: |-
      -----BEGIN PRIVATE KEY-----
      ...
      -----END PRIVATE KEY-----
```

For an existing Secret, put the private key under the key named by
`secret.keys.connectLinkPrivateKey` (default `DEN_CONNECT_LINK_PRIVATE_KEY`).
`scripts/generate-connect-link-keypair.mjs` can generate a pair, but a standard
desktop build will reject it until the matching public key ships in that build.

For a semi-air-gapped deployment, mount these normal release filenames (where
`<version>` is `installerReleaseTag` without its leading `v`):

- `openwork-mac-arm64-<version>.dmg`
- `openwork-mac-x64-<version>.dmg`
- `openwork-win-x64-<version>.exe`
- `openwork-linux-x86_64-<version>.AppImage`
- `openwork-linux-arm64-<version>.AppImage`

Without mounted artifacts, client networks must permit the configured GitHub
release URL and GitHub's redirected release-asset host. With mounted artifacts,
the browser only talks to Den. Use a shared read-only PVC when
`denApi.replicaCount` is greater than one. Connection grants are stored and
consumed in MySQL, so the guided flow is safe when preview and acceptance land
on different API replicas.

## Health Probes

The chart uses the existing service health endpoints:

- `den-api`: `GET /health`
- `den-web`: `GET /api/health`
- `inference`: `GET /health`

Readiness probes use dependency-aware endpoints:

- `den-api`: `GET /ready`
- `den-web`: `GET /api/ready`
- `inference`: `GET /ready`

## Worker Provisioning Recovery

`den-api` periodically reconciles cloud workers that remain in `provisioning` beyond `config.provisioner.reconcileStaleMs`. This lets a replacement pod resume provisioning after a crash. Keep `denApi.replicaCount: 1` unless your worker provider operations are idempotent or you add external leader election.
