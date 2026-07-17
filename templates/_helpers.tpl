{{- define "reitti.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "reitti.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Common labels; pass (dict "root" $ "component" "<name>") or the root context */}}
{{- define "reitti.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "reitti.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels for a component: include with (list $ "<component>") */}}
{{- define "reitti.componentSelectorLabels" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
app.kubernetes.io/name: {{ include "reitti.name" $root }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ $component }}
{{- end }}

{{/* Full image ref from a component image dict: include with (list $ .Values.<comp>.image) */}}
{{- define "reitti.image" -}}
{{- $root := index . 0 -}}
{{- $img := index . 1 -}}
{{- $tag := $img.tag | default $root.Chart.AppVersion | toString -}}
{{- $parts := list -}}
{{- with $img.registry }}{{- $parts = append $parts . }}{{- end -}}
{{- with $img.repository }}{{- $parts = append $parts . }}{{- end -}}
{{- $parts = append $parts (required "image.image is required" $img.image) -}}
{{- printf "%s:%s" (join "/" $parts) $tag -}}
{{- end }}

{{/* PostgreSQL host: explicit database.host wins, else derive from the CNPG cluster */}}
{{- define "reitti.databaseHost" -}}
{{- if .Values.database.host -}}
{{- .Values.database.host -}}
{{- else if .Values.cnpg.enabled -}}
{{- printf "%s-rw.%s.svc.cluster.local" .Values.cnpg.cluster.name .Values.cnpg.cluster.namespace -}}
{{- else -}}
{{- fail "set database.host or enable cnpg to derive it from the cluster" -}}
{{- end -}}
{{- end }}

{{/* Paikka public base URL: explicit value wins, else derived from its route */}}
{{- define "reitti.paikka.baseUrl" -}}
{{- if .Values.paikka.baseUrl -}}
{{- .Values.paikka.baseUrl -}}
{{- else if and .Values.paikka.httproute.enabled (.Values.paikka.httproute.hostnames | default list | first) -}}
{{- printf "https://%s" (.Values.paikka.httproute.hostnames | first) -}}
{{- else if and .Values.paikka.ingress.enabled (.Values.paikka.ingress.hosts | default list | first) -}}
{{- printf "http%s://%s" (ternary "s" "" (not (empty .Values.paikka.ingress.tls))) (.Values.paikka.ingress.hosts | first).host -}}
{{- else -}}
{{- printf "http://%s-paikka:%v" (include "reitti.fullname" .) .Values.paikka.service.port -}}
{{- end -}}
{{- end }}

{{/*
Generic Ingress for a component.
include with (dict "root" $ "svcName" "<svc>" "svcPort" <port> "ing" <ingress-values> "component" "<name>")
*/}}
{{- define "reitti.componentIngress" -}}
{{- if .ing.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .svcName }}
  labels:
    {{- include "reitti.labels" .root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
  {{- with .ing.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with .ing.className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with .ing.tls }}
  tls:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- $svcName := .svcName }}{{- $svcPort := .svcPort }}
    {{- range .ing.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType | default "Prefix" }}
            backend:
              service:
                name: {{ $svcName }}
                port:
                  number: {{ $svcPort }}
          {{- end }}
    {{- end }}
{{- end }}
{{- end }}

{{/*
Generic Gateway API HTTPRoute for a component.
include with (dict "root" $ "svcName" "<svc>" "svcPort" <port> "route" <httproute-values> "component" "<name>")
*/}}
{{- define "reitti.componentHTTPRoute" -}}
{{- if .route.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .svcName }}
  labels:
    {{- include "reitti.labels" .root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
  {{- with .route.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  parentRefs:
    {{- toYaml .route.parentRefs | nindent 4 }}
  {{- with .route.hostnames }}
  hostnames:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- if .route.rules }}
    {{- toYaml .route.rules | nindent 4 }}
    {{- else }}
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ''
          kind: Service
          name: {{ .svcName }}
          port: {{ .svcPort }}
          weight: 1
    {{- end }}
{{- end }}
{{- end }}
