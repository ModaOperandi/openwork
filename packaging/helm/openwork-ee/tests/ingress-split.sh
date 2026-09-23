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

assert_source_contains() {
  local file="$1"
  local source="$2"
  local needle="$3"
  local in_source=0
  local found=0
  local line

  while IFS= read -r line; do
    if [[ "$line" == '# Source: openwork-ee/templates/'* ]]; then
      if [[ "$line" == "# Source: openwork-ee/templates/$source" ]]; then
        in_source=1
      else
        in_source=0
      fi
    fi
    if [[ "$in_source" == 1 && "$line" == *"$needle"* ]]; then
      found=1
      break
    fi
  done < "$file"

  if [[ "$found" != 1 ]]; then
    printf 'Expected %s to contain %s\n' "$source" "$needle" >&2
    return 1
  fi
}

assert_source_not_contains() {
  local file="$1"
  local source="$2"
  local needle="$3"
  local in_source=0
  local line

  while IFS= read -r line; do
    if [[ "$line" == '# Source: openwork-ee/templates/'* ]]; then
      if [[ "$line" == "# Source: openwork-ee/templates/$source" ]]; then
        in_source=1
      else
        in_source=0
      fi
    fi
    if [[ "$in_source" == 1 && "$line" == *"$needle"* ]]; then
      printf 'Expected %s not to contain %s\n' "$source" "$needle" >&2
      return 1
    fi
  done < "$file"
}

# Disabled by default: neither Ingress renders.
disabled_rendered="$tmp_dir/disabled.yaml"
helm template openwork-ee "$chart_dir" > "$disabled_rendered"
assert_count "$disabled_rendered" 'kind: Ingress' 0

# Enabled with API disabled: only the web (den-web) Ingress renders.
api_disabled_values="$tmp_dir/api-disabled-values.yaml"
cat > "$api_disabled_values" <<'YAML'
ingress:
  enabled: true
  api:
    enabled: false
YAML
api_disabled_rendered="$tmp_dir/api-disabled.yaml"
helm template openwork-ee "$chart_dir" -f "$api_disabled_values" > "$api_disabled_rendered"
assert_count "$api_disabled_rendered" 'kind: Ingress' 1
assert_count "$api_disabled_rendered" 'name: openwork-ee-api' 0
assert_source_contains "$api_disabled_rendered" 'ingress-den.yaml' 'name: openwork-ee'
assert_source_contains "$api_disabled_rendered" 'ingress-den.yaml' 'host: "openwork.example.com"'
assert_source_contains "$api_disabled_rendered" 'ingress-den.yaml' 'name: openwork-ee-den-web'

# Enabled with API also enabled (the default `ingress.api.enabled`): two
# independently named Ingresses, each with its own host and backend service.
split_values="$tmp_dir/split-values.yaml"
cat > "$split_values" <<'YAML'
ingress:
  enabled: true
  annotations:
    shared-only: shared-value
    shared-and-overridden: shared-value
  web:
    host: web.example.com
    annotations:
      web-only: web-value
      shared-and-overridden: web-override
  api:
    host: api.example.com
    annotations:
      api-only: api-value
YAML
split_rendered="$tmp_dir/split.yaml"
helm template openwork-ee "$chart_dir" -f "$split_values" > "$split_rendered"

# Two Ingresses, independently named.
assert_count "$split_rendered" 'kind: Ingress' 2
assert_source_contains "$split_rendered" 'ingress-den.yaml' 'name: openwork-ee'
assert_source_not_contains "$split_rendered" 'ingress-den.yaml' 'name: openwork-ee-api'
assert_source_contains "$split_rendered" 'ingress-api.yaml' 'name: openwork-ee-api'

# Each Ingress rules to its own host and its own backend Service; neither
# leaks the other's host or Service name into its own render source.
assert_source_contains "$split_rendered" 'ingress-den.yaml' 'host: "web.example.com"'
assert_source_contains "$split_rendered" 'ingress-den.yaml' 'name: openwork-ee-den-web'
assert_source_not_contains "$split_rendered" 'ingress-den.yaml' 'host: "api.example.com"'
assert_source_not_contains "$split_rendered" 'ingress-den.yaml' 'name: openwork-ee-den-api'

assert_source_contains "$split_rendered" 'ingress-api.yaml' 'host: "api.example.com"'
assert_source_contains "$split_rendered" 'ingress-api.yaml' 'name: openwork-ee-den-api'
assert_source_not_contains "$split_rendered" 'ingress-api.yaml' 'host: "web.example.com"'
assert_source_not_contains "$split_rendered" 'ingress-api.yaml' 'name: openwork-ee-den-web'

# Shared annotations land on both Ingresses.
assert_source_contains "$split_rendered" 'ingress-den.yaml' 'shared-only: shared-value'
assert_source_contains "$split_rendered" 'ingress-api.yaml' 'shared-only: shared-value'

# Per-Ingress-only annotations land on exactly one Ingress each.
assert_source_contains "$split_rendered" 'ingress-den.yaml' 'web-only: web-value'
assert_source_not_contains "$split_rendered" 'ingress-api.yaml' 'web-only: web-value'
assert_source_contains "$split_rendered" 'ingress-api.yaml' 'api-only: api-value'
assert_source_not_contains "$split_rendered" 'ingress-den.yaml' 'api-only: api-value'

# A key set on both the shared and the web-specific annotation maps resolves
# to the web-specific value on the web Ingress (override wins), but keeps the
# shared value on the API Ingress (which set no override for that key).
assert_source_contains "$split_rendered" 'ingress-den.yaml' 'shared-and-overridden: web-override'
assert_source_not_contains "$split_rendered" 'ingress-den.yaml' 'shared-and-overridden: shared-value'
assert_source_contains "$split_rendered" 'ingress-api.yaml' 'shared-and-overridden: shared-value'
assert_source_not_contains "$split_rendered" 'ingress-api.yaml' 'shared-and-overridden: web-override'

printf 'ingress-split chart checks passed\n'
