{{/*
Create chart name and version as used by the chart label.
*/}}

{{- define "app.name" -}}
{{- print .Chart.Name -}}
{{- end -}}

{{- define "app.home" -}}
{{- print .Chart.Home -}}
{{- end -}}


{{/*
    ci-cd functions
*/}}

{{- define "argocd" -}}
{{- print "argocd" -}}
{{- end -}}

{{- define "ns.cicd" -}}
{{ printf "%s-ci-cd" .Chart.Name }}
{{- end -}}

{{- define "ns.development" -}}
{{ printf "%s-development" .Chart.Name }}
{{- end -}}

{{- define "cluster_apps" -}}
{{- print "apps.ocp-lab2.regsys.brreg.no" -}}
{{- end -}}

{{- define "nexus.helm.repository" -}}
{{- $ns := include "namespace" . -}}
{{- $cluster := include "cluster_apps" . -}}
{{ printf "https://nexus-%s.%s/repository/%s/" $ns $cluster .Chart.Name }}
{{- end -}}

{{/*
Common labels
*/}}

{{- define "platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "platform.labels" -}}
helm.sh/chart: {{ include "platform.chart" . }}
{{ include "platform.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
