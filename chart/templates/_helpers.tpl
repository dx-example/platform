{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "platform.name" -}}
{{- print .Chart.Name -}}
{{- end -}}

{{/*
    ci-cd functions
*/}}

{{- define "application" -}}
{{- print "dx-book" -}}
{{- end -}}

{{- define "namespace" -}}
{{- print "platform" -}}
{{- end -}}

{{- define "argocd" -}}
{{- print "argocd" -}}
{{- end -}}

{{/*
    scm functions
*/}}
{{- define "scm.url" -}}

{{- $split := printf "%s" .Chart.Home | replace "ssh://git@" "" | split "/" -}}
{{- printf "ssh://git@%s" $split._0 -}}
{{- end -}}

{{- define "scm.group" -}}
{{- $split := printf "%s" .Chart.Home | replace "ssh://git@" "" | split "/" -}}
{{- printf "%s" $split._1 -}}
{{- end -}}

{{- define "scm.repo" -}}
{{- $split := printf "%s" .Chart.Home | replace "ssh://git@" "" | split "/" -}}
{{- printf "%s" $split._2 | replace ".git" "" -}}
{{- end -}}

{{- define "scm.fullrepo" -}}
{{- $home := default .Chart.Home -}}
{{- print $home -}}
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
