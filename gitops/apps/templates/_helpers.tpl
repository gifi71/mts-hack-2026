{{/* Sync policy shared by every Application. */}}
{{- define "apps.syncPolicy" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  retry:
    limit: 10
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 3m
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
{{- end }}

{{/* Second source that exposes this repository as $values for Helm value files. */}}
{{- define "apps.valuesSource" -}}
- repoURL: {{ .Values.repoURL }}
  targetRevision: {{ .Values.targetRevision }}
  ref: values
{{- end }}
