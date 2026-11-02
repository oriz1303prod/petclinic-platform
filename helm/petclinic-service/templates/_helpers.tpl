{{/* Service name: values.serviceName, else the release name. Names of the Deployment, Service and ServiceAccount. */}}
{{- define "petclinic.name" -}}
{{- .Values.serviceName | default .Release.Name -}}
{{- end -}}

{{/* Selector labels. Never change these on a running Deployment (selector is immutable). */}}
{{- define "petclinic.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petclinic.name" . }}
app.kubernetes.io/part-of: petclinic
{{- end -}}

{{/* Recommended labels */}}
{{- define "petclinic.labels" -}}
{{ include "petclinic.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: {{ .Values.component }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Effective values: .Values with serviceOverrides.<serviceName> merged on top. Use: include ... | fromYaml */}}
{{- define "petclinic.values" -}}
{{- $v := toYaml .Values | fromYaml -}}
{{- $overrides := $v.serviceOverrides | default dict -}}
{{- $mine := get $overrides (include "petclinic.name" .) | default dict -}}
{{- $_ := mustMergeOverwrite $v $mine -}}
{{- toYaml $v -}}
{{- end -}}

{{/* Namespace: values.namespace, else the release namespace */}}
{{- define "petclinic.namespace" -}}
{{- .Values.namespace | default .Release.Namespace -}}
{{- end -}}

{{/* Image reference: {registry}/{name}:{tag}. Pass the effective values as .v and the root context as .root */}}
{{- define "petclinic.image" -}}
{{- $v := .v -}}
{{- $name := $v.image.name | default (include "petclinic.name" .root) -}}
{{- $tag := required "image.tag is required (use the commit SHA, never latest)" $v.image.tag -}}
{{- if $v.image.registry -}}
{{- printf "%s/%s:%s" $v.image.registry $name $tag -}}
{{- else -}}
{{- printf "%s:%s" $name $tag -}}
{{- end -}}
{{- end -}}
