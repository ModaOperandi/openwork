#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_count() {
  local file="$1"
  local needle="$2"
  local expected="$3"
  local count
  count="$(grep -F -c -- "$needle" "$file" || true)"
  if [[ "$count" != "$expected" ]]; then
    printf 'Expected %s occurrences of %s, found %s\n' "$expected" "$needle" "$count" >&2
    return 1
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -F -q -- "$needle" "$file"; then
    printf 'Expected rendered chart to contain %s\n' "$needle" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -F -q -- "$needle" "$file"; then
    printf 'Expected rendered chart not to contain %s\n' "$needle" >&2
    return 1
  fi
}

# Default render: createNamespace now defaults to false (Helm's own
# --create-namespace flag already covers the direct-Helm case, and enabling
# this hook by default was actively dangerous under ArgoCD — see
# templates/namespace.yaml). No Namespace object renders unless explicitly
# opted into. 8 namespaced resources: Secret, ConfigMap, den-api/den-web
# Services+Deployments, migration Job, env-probe test Job.
default_rendered="$tmp_dir/default.yaml"
helm template openwork-ee "$chart_dir" > "$default_rendered"
assert_count "$default_rendered" 'kind: Namespace' 0
assert_count "$default_rendered" '  namespace: "openwork"' 8
assert_count "$default_rendered" '  namespace: "kube-system"' 0

# Opting in (createNamespace=true) with the migration hook enabled (default)
# renders the Namespace as the earliest hook so first-time installs into a
# fresh namespace work: hook resources (ExternalSecret, migration RBAC/Job)
# are namespaced and would otherwise be created before a normal-manifest
# Namespace exists.
opt_in_rendered="$tmp_dir/opt-in.yaml"
helm template openwork-ee "$chart_dir" --set createNamespace=true > "$opt_in_rendered"
assert_count "$opt_in_rendered" 'kind: Namespace' 1
assert_contains "$opt_in_rendered" 'name: "openwork"'
assert_contains "$opt_in_rendered" 'helm.sh/hook-weight": "-11"'
# The rendered Namespace hook must never carry an explicit hook-delete-policy
# annotation: an explicit before-hook-creation would be no different from the
# Helm/Argo CD default for an unannotated hook (both explicitly document
# that before-hook-creation is what applies when no policy is set) — but
# omitting it keeps the door open for genuine (non-ArgoCD) `helm install`/
# `helm upgrade` runs, where the lookup() guard above has real cluster access
# and skips rendering this hook at all once the namespace exists, so the
# dangerous default is never reached in that path. It IS reached on every
# ArgoCD sync (lookup() always returns empty there) — ArgoCD deployments must
# leave createNamespace at its false default and use
# `syncOptions: [CreateNamespace=true]` instead; see the long comment atop
# templates/namespace.yaml.
# (The env-probe test Job legitimately uses before-hook-creation, so scope the
# check to the Namespace document.)
assert_namespace_hook_safe() {
  local file="$1"
  local in_ns=0
  local line
  while IFS= read -r line; do
    if [[ "$line" == 'kind: Namespace' ]]; then
      in_ns=1
    elif [[ "$line" == '---' ]]; then
      in_ns=0
    fi
    if [[ "$in_ns" == 1 && "$line" == *'hook-delete-policy'* ]]; then
      printf 'Namespace must not carry an explicit hook-delete-policy annotation\n' >&2
      return 1
    fi
  done < "$file"
}
assert_namespace_hook_safe "$opt_in_rendered"
# Defense in depth against Helm's release-tracking semantics across mode
# transitions this template cannot fully control from either side alone
# (e.g. migrations.hook flipping true->false->true across upgrades, or a
# pre-existing release from before non-hook rendering existed): the
# Namespace always carries helm.sh/resource-policy: keep, which Helm's own
# docs state "instructs Helm to skip deleting this resource when a helm
# operation (such as helm uninstall, helm upgrade or helm rollback) would
# result in its deletion" — unconditionally, regardless of how the resource
# is currently classified. The resource is orphaned (unmanaged) rather than
# actively kept in sync if such a transition happens, but never deleted.
assert_contains "$opt_in_rendered" 'helm.sh/resource-policy": keep'

# With createNamespace=true but the migration hook disabled, the Namespace is
# a plain (non-hook) manifest.
nohook_rendered="$tmp_dir/nohook.yaml"
helm template openwork-ee "$chart_dir" --set createNamespace=true --set migrations.hook=false > "$nohook_rendered"
assert_count "$nohook_rendered" 'kind: Namespace' 1
assert_count "$nohook_rendered" 'helm.sh/hook-weight": "-11"' 0
assert_contains "$nohook_rendered" 'helm.sh/resource-policy": keep'
# Regression: the plain-manifest Namespace must render unconditionally here
# (no lookup-gated skip), never carrying any helm.sh/hook annotation. Helm
# exempts hook resources from release-manifest tracking/pruning ("hook
# resources are not managed with corresponding releases") but NOT plain
# resources — if this path reused the hook path's lookup-and-skip-once-
# existing trick, the first `helm install` would render (and track) it once,
# then every later `helm upgrade` would omit it because lookup finds it,
# which Helm reads as "removed from the chart" and deletes — cascading
# everything in the namespace, on the *second* upgrade of a perfectly normal,
# supported migrations.hook=false configuration.
assert_not_contains "$nohook_rendered" '"helm.sh/hook": pre-install'

# createNamespace=false (the default, set explicitly here) skips the
# Namespace object entirely (out-of-band provisioning, e.g. --create-namespace
# or ArgoCD's own CreateNamespace=true syncOption).
no_nsdef_rendered="$tmp_dir/no-nsdef.yaml"
helm template openwork-ee "$chart_dir" --set createNamespace=false > "$no_nsdef_rendered"
assert_count "$no_nsdef_rendered" 'kind: Namespace' 0

# Full render (ingress + inference + createNamespace all enabled): Namespace +
# 11 namespaced resources.
full_rendered="$tmp_dir/full.yaml"
helm template openwork-ee "$chart_dir" \
  --set createNamespace=true --set ingress.enabled=true --set inference.enabled=true > "$full_rendered"
assert_count "$full_rendered" 'kind: Namespace' 1
assert_count "$full_rendered" '  namespace: "openwork"' 11

# Explicit override wins on every resource.
override_rendered="$tmp_dir/override.yaml"
helm template openwork-ee "$chart_dir" --set namespace=platform > "$override_rendered"
assert_count "$override_rendered" '  namespace: "platform"' 8
assert_count "$override_rendered" '  namespace: "openwork"' 0

# Cleared value falls back to the release namespace.
fallback_rendered="$tmp_dir/fallback.yaml"
helm template openwork-ee "$chart_dir" --namespace rel-ns --set namespace= > "$fallback_rendered"
assert_count "$fallback_rendered" '  namespace: "rel-ns"' 8

# The Namespace object name follows the namespace value.
nsdef_override_rendered="$tmp_dir/nsdef-override.yaml"
helm template openwork-ee "$chart_dir" --set createNamespace=true --set namespace=platform > "$nsdef_override_rendered"
assert_count "$nsdef_override_rendered" 'kind: Namespace' 1
assert_contains "$nsdef_override_rendered" 'name: "platform"'

# Numeric and YAML-keyword overrides stay quoted strings: --set types these as
# number/bool, and metadata.namespace must render as a quoted string.
numeric_rendered="$tmp_dir/numeric.yaml"
helm template openwork-ee "$chart_dir" --set namespace=123 > "$numeric_rendered"
assert_count "$numeric_rendered" '  namespace: "123"' 8
assert_count "$numeric_rendered" '  namespace: 123' 0

keyword_rendered="$tmp_dir/keyword.yaml"
helm template openwork-ee "$chart_dir" --set namespace=yes > "$keyword_rendered"
assert_count "$keyword_rendered" '  namespace: "yes"' 8
assert_count "$keyword_rendered" '  namespace: yes' 0

printf 'namespace chart checks passed\n'
