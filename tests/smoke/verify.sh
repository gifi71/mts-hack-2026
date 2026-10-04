#!/usr/bin/env bash
# Smoke tests for the deployed platform. Runs on the Kubernetes node
# (`make verify` copies and runs it there), needs kubectl, curl and python3.
#
#   1. Cluster and Argo CD applications are healthy
#   2. The app answers through Gateway API: HTTP, HTTPS, header/path routing, traffic split
#   3. Prometheus scrapes the app and the gateway, PromQL returns data
#   4. Kyverno admits the signed Fluentd image and denies an unsigned one
#   5. Access and error log lines with a unique marker show up in Loki (Fluentd pipeline)
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
HTTP_URL="http://${NODE_IP}:30080"
HTTPS_PORT=30443
APP_HOST=app.mts-hack.local
MARKER="verify-$(date +%s)-$RANDOM"

failures=0
warnings=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
# Optional features that depend on external services: reported, not counted as failures.
warn() { echo "WARN  $*"; warnings=$((warnings + 1)); }
section() { echo; echo "== $*"; }
# check "description" <test command...>: PASS/FAIL by the command's exit status.
check() {
  local desc=$1; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}
# check_warn "description" <test command...>: PASS, or WARN instead of FAIL.
check_warn() {
  local desc=$1; shift
  if "$@"; then pass "$desc"; else warn "$desc"; fi
}
# shellcheck disable=SC2317,SC2329 # called through check
contains() { [[ "$1" == *"$2"* ]]; }
# shellcheck disable=SC2317,SC2329 # called through check
between() { (($1 >= $2 && $1 <= $3)); }

# Kubernetes API proxy to a Service: no port-forward, works from the node.
svc_get() { # namespace service:port path
  kubectl get --raw "/api/v1/namespaces/$1/services/$2/proxy$3"
}
urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
# API errors (e.g. 503 right after the deploy) count as "no data yet"; the retries handle the rest.
EMPTY_RESULT='{"data":{"result":[]}}'
promql() { # query -> number of series
  { svc_get monitoring kube-prometheus-stack-prometheus:9090 "/api/v1/query?query=$(urlencode "$1")" 2>/dev/null ||
    echo "$EMPTY_RESULT"; } |
    python3 -c 'import sys, json; print(len(json.load(sys.stdin)["data"]["result"]))'
}
loki_find() { # LogQL query -> first matching line within 2 minutes, empty if none
  local query start line=""
  query=$(urlencode "$1")
  start=$(($(date +%s) - 300))000000000
  for _ in $(seq 1 24); do
    line=$({ svc_get logging loki:3100 "/loki/api/v1/query_range?query=${query}&start=${start}&limit=1" 2>/dev/null ||
      echo "$EMPTY_RESULT"; } |
      python3 -c 'import sys, json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["values"][0][1] if r else "")')
    [[ -n "$line" ]] && break
    sleep 5
  done
  echo "$line"
}
# Retries for up to 2 minutes: right after a deploy targets may not be scraped yet.
promql_wait() { # query min_series -> number of series
  local n=0
  for _ in $(seq 1 12); do
    n=$(promql "$1")
    ((n >= $2)) && break
    sleep 10
  done
  echo "$n"
}

section "Cluster"
if kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; then
  pass "node Ready: $(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}')"
else
  fail "node not Ready"
fi
not_ready=$(kubectl -n argocd get applications.argoproj.io --no-headers \
  -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status | grep -v 'Synced *Healthy' || true)
apps=$(kubectl -n argocd get applications.argoproj.io --no-headers 2>/dev/null | wc -l)
if ((apps == 0)); then
  fail "Argo CD: no applications, the root Application is missing"
elif [[ -z "$not_ready" ]]; then
  pass "Argo CD: ${apps} applications Synced/Healthy"
else
  fail "Argo CD applications not Synced/Healthy:"
  while IFS= read -r line; do echo "      $line"; done <<<"$not_ready"
fi

section "Gateway API (Envoy Gateway, NodePort ${HTTP_URL})"
programmed=$(kubectl -n envoy-gateway-system get gateway edge -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
check "Gateway edge Programmed (${programmed:-unknown})" test "$programmed" = True

body=$(curl -fsS --max-time 5 "${HTTP_URL}/" || true)
check "curl ${HTTP_URL}/ -> '${body}'" contains "$body" "Hello World!"

ca=$(mktemp)
trap 'rm -f "$ca"' EXIT
kubectl -n cert-manager get secret mts-hack-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca"
https() { curl -fsS --max-time 5 --cacert "$ca" --resolve "${APP_HOST}:${HTTPS_PORT}:${NODE_IP}" "$@"; }

body=$(https "https://${APP_HOST}:${HTTPS_PORT}/" || true)
check "HTTPS with the cert-manager CA -> '${body}'" contains "$body" "Hello World!"

body=$(https -H 'X-Canary: always' "https://${APP_HOST}:${HTTPS_PORT}/" || true)
check "header X-Canary: always -> v2 ('${body}')" contains "$body" "v2"

body=$(https "https://${APP_HOST}:${HTTPS_PORT}/v2/" || true)
check "path /v2/ (rewritten to /) -> v2 ('${body}')" contains "$body" "v2"

v2=0
for _ in $(seq 1 100); do
  if contains "$(https "https://${APP_HOST}:${HTTPS_PORT}/" || true)" "v2"; then v2=$((v2 + 1)); fi
done
check "traffic split 90/10: v2 served ${v2}/100 requests" between "$v2" 1 30

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${HTTP_URL}/missing" || true)
check "curl ${HTTP_URL}/missing -> ${code} (expected 404)" test "$code" = 404
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${HTTP_URL}/error" || true)
check "curl ${HTTP_URL}/error -> ${code} (expected 500)" test "$code" = 500

section "Prometheus"
for job in angie-v1 angie-v2; do
  n=$(promql_wait "up{namespace=\"demo\",service=\"${job}\"} == 1" 1)
  check "target ${job} up (${n} pods)" between "$n" 1 100
done
n=$(promql_wait 'up{job=~".*envoy.*"} == 1' 1)
check "Envoy targets up (${n})" between "$n" 1 100
n=$(promql_wait 'angie_http_server_zones_responses{zone="demo"}' 1)
check "PromQL angie_http_server_zones_responses{zone=\"demo\"}: ${n} series" between "$n" 1 100
n=$(promql_wait 'count by (__name__) ({__name__=~"envoy_cluster_upstream_rq_total|node_cpu_seconds_total|kube_pod_status_ready|apiserver_request_total"})' 4)
check "PromQL: Envoy, node-exporter, kube-state-metrics, apiserver metrics (${n}/4)" test "$n" -eq 4
n=$(promql_wait 'slo:sli_error:ratio_rate5m{sloth_service="demo-app"}' 2)
check "SLO recording rules (Sloth): availability and latency SLIs (${n}/2)" test "$n" -ge 2
echo "      Angie responses by code: $({ svc_get monitoring kube-prometheus-stack-prometheus:9090 \
  "/api/v1/query?query=$(urlencode 'sum by (code) (angie_http_server_zones_responses{zone="demo"})')" 2>/dev/null ||
  echo "$EMPTY_RESULT"; } |
  python3 -c 'import sys, json; print(", ".join(r["metric"]["code"] + "=" + r["value"][1] for r in json.load(sys.stdin)["data"]["result"]))')"

section "Admission policies (Kyverno)"
# The signed image must be admitted, or Fluentd cannot start: a hard check. Rejecting an
# unsigned image needs ghcr.io and Sigstore (Rekor, TUF) from the node; when they are not
# reachable, Kyverno lets pods through (failurePolicy: Ignore), so those checks only warn.
# Server-side dry runs: the API server calls the Kyverno webhook, nothing is created.
dry_run_pod() { # name image -> admission output
  kubectl -n logging run "$1" --image="$2" --restart=Never --dry-run=server -o name 2>&1 || true
}
signed=$(kubectl -n logging get daemonset fluentd -o jsonpath='{.spec.template.spec.containers[0].image}')
out=$(dry_run_pod verify-signed "$signed")
check "signed Fluentd image admitted (${signed##*/})" contains "$out" "pod/verify-signed"
# The tag cosign creates next to a signed image (sha256-<digest>) is an artifact without a
# signature of its own: the policy must reject it by digest.
repo=gifi71/mts-hack-2026/fluentd
token_json=$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" || echo '{"token": ""}')
token=$(python3 -c 'import sys, json; print(json.loads(sys.argv[1]).get("token", ""))' "$token_json")
artifact=$(curl -fsSI -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/${repo}/manifests/sha256-${signed##*@sha256:}" 2>/dev/null |
  awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}' | tr -d '\r' || true)
if [[ -z "$artifact" ]]; then
  warn "unsigned image check skipped: ghcr.io is not reachable from the node"
else
  out=$(dry_run_pod verify-unsigned "ghcr.io/${repo}@${artifact}")
  check_warn "unsigned image of this repository denied: ${out##*failed: }" contains "$out" "must carry the cosign signature"
fi
n=$(kubectl get policyreports -A --no-headers 2>/dev/null | wc -l)
check_warn "PolicyReports for workload policies (${n})" between "$n" 1 100000

section "Logging (Fluentd -> Loki)"
curl -fsS --max-time 5 -o /dev/null "${HTTP_URL}/?marker=${MARKER}" || true
curl -s --max-time 5 -o /dev/null "${HTTP_URL}/missing?marker=${MARKER}" || true

# app="angie" is the label the Grafana dashboard filters on.
found=$(loki_find "{namespace=\"demo\", app=\"angie\", stream=\"stdout\"} |= \"${MARKER}\"")
if [[ -n "$found" ]]; then
  pass "access log (stdout) for ?marker=${MARKER} found in Loki:"
  echo "      ${found}"
else
  fail "access log with marker ${MARKER} not in Loki after 2 minutes"
fi

found=$(loki_find "{namespace=\"demo\", stream=\"stderr\"} |= \"${MARKER}\"")
if [[ -n "$found" ]]; then
  pass "error log (stderr) for /missing?marker=${MARKER} found in Loki:"
  echo "      ${found:0:300}"
else
  fail "error log with marker ${MARKER} not in Loki after 2 minutes"
fi

echo
note=""
((warnings > 0)) && note=" ${warnings} warning(s): optional checks that need external services, see WARN above."
if ((failures == 0)); then echo "All checks passed.${note}"; else echo "${failures} check(s) failed.${note}"; fi
exit "$failures"
