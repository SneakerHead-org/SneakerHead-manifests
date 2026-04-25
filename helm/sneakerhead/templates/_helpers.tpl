{{/*
Expand the name of the chart.
*/}}
{{- define "sneakerhead.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "sneakerhead.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart label for chart version.
*/}}
{{- define "sneakerhead.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "sneakerhead.labels" -}}
helm.sh/chart: {{ include "sneakerhead.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Values.global.labels.partOf }}
environment: {{ .Values.global.environment }}
{{- end }}

{{/*
Namespace helper.
*/}}
{{- define "sneakerhead.namespace" -}}
{{ .Values.global.namespace }}
{{- end }}

{{/*
Image helper — builds full image string from repository and tag.
Usage: {{ include "sneakerhead.image" .Values.image }}
*/}}
{{- define "sneakerhead.image" -}}
{{- printf "%s:%s" .repository .tag }}
{{- end }}
