{{- define "openwork-ee.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openwork-ee.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- /*
  Dedupe in both directions: contains handles release names that already
  include the chart name (my-openwork-ee); hasPrefix handles release names
  that prefix the chart name (release "openwork", chart "openwork-ee"), which
  would otherwise produce doubled names like openwork-openwork-ee-secret.
*/ -}}
{{- if or (contains $name .Release.Name) (hasPrefix .Release.Name $name) -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openwork-ee.namespace" -}}
{{- .Values.namespace | default .Release.Namespace | toString | quote -}}
{{- end -}}

{{- define "openwork-ee.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openwork-ee.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openwork-ee.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "openwork-ee.labels" -}}
helm.sh/chart: {{ include "openwork-ee.chart" . }}
{{ include "openwork-ee.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "openwork-ee.componentSelectorLabels" -}}
{{ include "openwork-ee.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "openwork-ee.componentLabels" -}}
{{ include "openwork-ee.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "openwork-ee.configName" -}}
{{ include "openwork-ee.fullname" . }}-config
{{- end -}}

{{- define "openwork-ee.allowPrivateMcpUrls" -}}
{{- $value := .Values.config.public.allowPrivateMcpUrls | default "" | toString | trim | lower -}}
{{- if eq $value "1" -}}
1
{{- else if or (eq $value "") (eq $value "0") (eq $value "false") -}}
{{- else -}}
{{- fail "config.public.allowPrivateMcpUrls must be blank, 0, false, or \"1\"" -}}
{{- end -}}
{{- end -}}

{{/*
  Returns the workload Secret name as a quoted string: existingSecret values
  are user-supplied and may look like YAML scalars (true, 1234), which would
  otherwise render non-string manifest fields and fail at apply time.
  Consumers that need the bare name trim the quotes.
*/}}
{{- define "openwork-ee.secretName" -}}
{{- if eq .Values.secret.secretsMode "existingSecret" -}}
{{- .Values.secret.existingSecret | toString | trim | quote -}}
{{- else -}}
{{- printf "%s-secret" (include "openwork-ee.fullname" .) | quote -}}
{{- end -}}
{{- end -}}

{{/* Bare (unquoted) Secret name for contexts that need it (e.g. lookup). */}}
{{- define "openwork-ee.secretNameRaw" -}}
{{- include "openwork-ee.secretName" . | trimAll "\"" -}}
{{- end -}}

{{/* Bare (unquoted) namespace name for contexts that need it. */}}
{{- define "openwork-ee.namespaceRaw" -}}
{{- include "openwork-ee.namespace" . | trimAll "\"" -}}
{{- end -}}

{{- define "openwork-ee.secretsMode.validate" -}}
{{- if not (has .Values.secret.secretsMode (list "inline" "existingSecret" "externalSecrets")) -}}
{{- fail "secretsMode must be one of inline, existingSecret, externalSecrets" -}}
{{- end -}}
{{- if eq .Values.secret.secretsMode "existingSecret" -}}
{{- if not (.Values.secret.existingSecret | toString | trim) -}}
{{- fail "secret.existingSecret is required when secretsMode=existingSecret" -}}
{{- end -}}
{{- end -}}
{{- if ne .Values.secret.secretsMode "existingSecret" -}}
{{- if .Values.secret.existingSecret -}}
{{- fail "secret.existingSecret is only allowed when secretsMode=existingSecret" -}}
{{- end -}}
{{- end -}}
{{- if ne .Values.secret.secretsMode "inline" -}}
{{- if .Values.secret.create -}}
{{- fail "secret.create must be false when secretsMode is not inline" -}}
{{- end -}}
{{- end -}}
{{- if and (eq .Values.secret.secretsMode "inline") (not .Values.secret.create) -}}
{{- /* Legacy migration shim: values files from before secretsMode shipped that
       set create=false with untouched placeholder values meant "no inline
       secrets" — treat that as existingSecret mode. Real-looking values with
       create=false are incoherent and must fail, not be silently rerouted. */ -}}
{{- $dsn := .Values.secret.values.databaseUrl | toString -}}
{{- $auth := .Values.secret.values.betterAuthSecret | toString -}}
{{- $enc := .Values.secret.values.denDbEncryptionKey | toString -}}
{{- /*
  Reroute only when ALL three required values are still placeholders: a
  partially-filled inline block means someone set real values and create=false
  is incoherent — fail rather than silently ignoring their real values.
*/ -}}
{{- $dsnIsPlaceholder := or (contains "change-me@" $dsn) (contains "******" $dsn) -}}
{{- if and (hasPrefix "CHANGE_ME" $auth) (hasPrefix "CHANGE_ME" $enc) $dsnIsPlaceholder -}}
{{- $_ := set .Values.secret "secretsMode" "existingSecret" -}}
{{- if not (.Values.secret.existingSecret | toString | trim) -}}
{{- $_ := set .Values.secret "existingSecret" (include "openwork-ee.fullname" . | printf "%s-secret") -}}
{{- end -}}
{{- else -}}
{{- fail "secret.create must be true when secretsMode=inline (set secretsMode=existingSecret or externalSecrets to source secrets externally)" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openwork-ee.externalSecrets.apiVersion" -}}
{{- if .Capabilities.APIVersions.Has "external-secrets.io/v1" -}}
external-secrets.io/v1
{{- else -}}
external-secrets.io/v1beta1
{{- end -}}
{{- end -}}

{{- define "openwork-ee.externalSecrets.validate" -}}
{{- if eq .Values.secret.secretsMode "externalSecrets" -}}
{{- $storeName := "" -}}
{{- if .Values.externalSecrets.secretStoreRef -}}
{{- $storeName = .Values.externalSecrets.secretStoreRef.name | toString | trim -}}
{{- end -}}
{{- if not $storeName -}}
{{- fail "externalSecrets.secretStoreRef.name is required when secretsMode=externalSecrets" -}}
{{- end -}}
{{- $storeKind := "" -}}
{{- if .Values.externalSecrets.secretStoreRef -}}
{{- $storeKind = .Values.externalSecrets.secretStoreRef.kind | toString -}}
{{- end -}}
{{- if not (has $storeKind (list "SecretStore" "ClusterSecretStore")) -}}
{{- fail "externalSecrets.secretStoreRef.kind must be SecretStore or ClusterSecretStore" -}}
{{- end -}}
{{- if not (.Values.externalSecrets.pathPrefix | toString | trim) -}}
{{- fail "externalSecrets.pathPrefix is required when secretsMode=externalSecrets" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openwork-ee.denApiServiceName" -}}
{{ include "openwork-ee.fullname" . }}-den-api
{{- end -}}

{{- define "openwork-ee.denWebServiceName" -}}
{{ include "openwork-ee.fullname" . }}-den-web
{{- end -}}

{{- define "openwork-ee.inferenceServiceName" -}}
{{ include "openwork-ee.fullname" . }}-inference
{{- end -}}

{{- define "openwork-ee.denApiInternalUrl" -}}
{{- default (printf "http://%s:%v" (include "openwork-ee.denApiServiceName" .) .Values.denApi.service.port) .Values.config.internal.apiBaseUrl -}}
{{- end -}}

{{- define "openwork-ee.authFallbackInternalUrl" -}}
{{- default (include "openwork-ee.denApiInternalUrl" .) .Values.config.internal.authFallbackBaseUrl -}}
{{- end -}}

{{- define "openwork-ee.inferenceInternalUrl" -}}
{{- default (printf "http://%s:%v" (include "openwork-ee.inferenceServiceName" .) .Values.inference.service.port) .Values.config.internal.inferenceProxyBaseUrl -}}
{{- end -}}

{{- define "openwork-ee.customCa.mountPath" -}}
/etc/openwork/custom-ca
{{- end -}}

{{- define "openwork-ee.customCa.filePath" -}}
{{ include "openwork-ee.customCa.mountPath" . }}/ca-bundle.pem
{{- end -}}

{{- define "openwork-ee.customCa.validate" -}}
{{- if .Values.customCa.enabled -}}
{{- if and .Values.customCa.existingSecret .Values.customCa.existingConfigMap -}}
{{- fail "customCa.existingSecret and customCa.existingConfigMap are mutually exclusive when customCa.enabled=true" -}}
{{- end -}}
{{- if not (or .Values.customCa.existingSecret .Values.customCa.existingConfigMap) -}}
{{- fail "customCa.existingSecret or customCa.existingConfigMap is required when customCa.enabled=true" -}}
{{- end -}}
{{- if not .Values.customCa.key -}}
{{- fail "customCa.key is required when customCa.enabled=true" -}}
{{- end -}}
{{- if hasKey .Values.denApi.env "NODE_EXTRA_CA_CERTS" -}}
{{- fail "denApi.env.NODE_EXTRA_CA_CERTS conflicts with customCa.enabled=true; remove it and use customCa instead" -}}
{{- end -}}
{{- if hasKey .Values.denWeb.env "NODE_EXTRA_CA_CERTS" -}}
{{- fail "denWeb.env.NODE_EXTRA_CA_CERTS conflicts with customCa.enabled=true; remove it and use customCa instead" -}}
{{- end -}}
{{- if hasKey .Values.inference.env "NODE_EXTRA_CA_CERTS" -}}
{{- fail "inference.env.NODE_EXTRA_CA_CERTS conflicts with customCa.enabled=true; remove it and use customCa instead" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openwork-ee.customCa.volume" -}}
- name: custom-ca
  {{- if .Values.customCa.existingSecret }}
  secret:
    secretName: {{ .Values.customCa.existingSecret | quote }}
    items:
      - key: {{ .Values.customCa.key | quote }}
        path: ca-bundle.pem
  {{- else }}
  configMap:
    name: {{ .Values.customCa.existingConfigMap | quote }}
    items:
      - key: {{ .Values.customCa.key | quote }}
        path: ca-bundle.pem
  {{- end }}
{{- end -}}

{{- define "openwork-ee.customCa.volumeMount" -}}
- name: custom-ca
  mountPath: {{ include "openwork-ee.customCa.mountPath" . | quote }}
  readOnly: true
{{- end -}}

{{- define "openwork-ee.customCa.env" -}}
- name: NODE_EXTRA_CA_CERTS
  value: {{ include "openwork-ee.customCa.filePath" . | quote }}
{{- end -}}

{{- define "openwork-ee.observabilityBackend" -}}
{{- $backend := default "none" .Values.observability.backend -}}
{{- if not (has $backend (list "none" "otel" "sentry")) -}}
{{- fail "observability.backend must be one of none, otel, sentry" -}}
{{- end -}}
{{- $backend -}}
{{- end -}}

{{- define "openwork-ee.observabilityOtelExporter" -}}
{{- $exporter := default "otlp" .value -}}
{{- if not (has $exporter (list "otlp" "none")) -}}
{{- fail (printf "observability.otel.exporters.%s must be otlp or none" .signal) -}}
{{- end -}}
{{- $exporter -}}
{{- end -}}

{{- define "openwork-ee.observabilityOtelSampler" -}}
{{- $sampler := default "parentbased_always_on" . -}}
{{- if not (has $sampler (list "always_on" "always_off" "traceidratio" "parentbased_always_on" "parentbased_always_off" "parentbased_traceidratio")) -}}
{{- fail "observability.otel.tracesSampler must be a standard OpenTelemetry sampler" -}}
{{- end -}}
{{- $sampler -}}
{{- end -}}

{{- define "openwork-ee.observabilityEnv" -}}
{{- $root := .root -}}
{{- $serviceName := .serviceName -}}
{{- $backend := include "openwork-ee.observabilityBackend" $root -}}
{{- $otel := $root.Values.observability.otel -}}
{{- $sentry := $root.Values.observability.sentry -}}
- name: DEN_OBSERVABILITY_BACKEND
  value: {{ $backend | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ $serviceName | quote }}
{{- if eq $backend "otel" }}
{{- $otelSampler := include "openwork-ee.observabilityOtelSampler" $otel.tracesSampler -}}
{{- $otelProtocol := default "http/protobuf" $otel.protocol -}}
{{- if ne $otelProtocol "http/protobuf" }}
{{- fail "observability.otel.protocol must be http/protobuf" -}}
{{- end }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: {{ $otelProtocol | quote }}
{{- with $otel.endpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with $otel.tracesEndpoint }}
- name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with $otel.metricsEndpoint }}
- name: OTEL_EXPORTER_OTLP_METRICS_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with $otel.logsEndpoint }}
- name: OTEL_EXPORTER_OTLP_LOGS_ENDPOINT
  value: {{ . | quote }}
{{- end }}
- name: OTEL_TRACES_EXPORTER
  value: {{ include "openwork-ee.observabilityOtelExporter" (dict "signal" "traces" "value" $otel.exporters.traces) | quote }}
- name: OTEL_METRICS_EXPORTER
  value: {{ include "openwork-ee.observabilityOtelExporter" (dict "signal" "metrics" "value" $otel.exporters.metrics) | quote }}
- name: OTEL_LOGS_EXPORTER
  value: {{ include "openwork-ee.observabilityOtelExporter" (dict "signal" "logs" "value" $otel.exporters.logs) | quote }}
- name: OTEL_TRACES_SAMPLER
  value: {{ $otelSampler | quote }}
{{- if has $otelSampler (list "traceidratio" "parentbased_traceidratio") }}
- name: OTEL_TRACES_SAMPLER_ARG
  value: {{ default "1" $otel.tracesSamplerArg | quote }}
{{- else if and $otel.tracesSamplerArg (ne (toString $otel.tracesSamplerArg) "1") }}
{{- fail "observability.otel.tracesSamplerArg is only supported for traceidratio samplers" -}}
{{- end }}
{{- with $otel.headers.existingSecret }}
- name: OTEL_EXPORTER_OTLP_HEADERS
  valueFrom:
    secretKeyRef:
      name: {{ . | quote }}
      key: {{ $otel.headers.key | quote }}
{{- end }}
{{- else if eq $backend "sentry" }}
{{- if and $sentry.dsn $sentry.dsnSecret.existingSecret }}
{{- fail "observability.sentry.dsn and observability.sentry.dsnSecret.existingSecret are mutually exclusive" -}}
{{- end }}
{{- if not (or $sentry.dsn $sentry.dsnSecret.existingSecret) }}
{{- fail "observability.sentry.dsn or observability.sentry.dsnSecret.existingSecret is required when observability.backend=sentry" -}}
{{- end }}
- name: SENTRY_DSN
{{- if $sentry.dsn }}
  value: {{ $sentry.dsn | quote }}
{{- else }}
  valueFrom:
    secretKeyRef:
      name: {{ $sentry.dsnSecret.existingSecret | quote }}
      key: {{ $sentry.dsnSecret.key | quote }}
{{- end }}
- name: SENTRY_TRACES_SAMPLE_RATE
  value: {{ $sentry.tracesSampleRate | quote }}
{{- with $sentry.environment }}
- name: SENTRY_ENVIRONMENT
  value: {{ . | quote }}
{{- end }}
{{- with $sentry.release }}
- name: SENTRY_RELEASE
  value: {{ . | quote }}
{{- end }}
{{- with $sentry.dist }}
- name: SENTRY_DIST
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}
