#!/usr/bin/env bash
# Smoke tests for the deployed platform. Runs on the Kubernetes node
# (`make verify` copies and runs it there), needs kubectl, curl and python3.
#
#   1. Cluster and Argo CD applications are healthy
#   2. The app answers through Gateway API: HTTP, HTTPS, header/path routing, traffic split
#   3. Prometheus scrapes the app and the gateway, PromQL returns data
#   4. A request with a unique marker shows up in Loki (Fluentd pipeline)
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
HTTP_URL="http://${NODE_IP}:30080"
HTTPS_PORT=30443
APP_HOST=app.mts-hack.local
MARKER="verify-$(date +%s)-$RANDOM"

failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
section() { echo; echo "== $*"; }
# check "description" <test command...>: PASS/FAIL by the command's exit status.
check() {
  local desc=$1; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}
# shellcheck disable=SC2329 # called through check
contains() { [[ "$1" == *"$2"* ]]; }
# shellcheck disable=SC2329 # called through check
between() { (($1 >= $2 && $1 <= $3)); }

# Kubernetes API proxy to a Service: no port-forward, works from the node.
svc_get() { # namespace service:port path
  kubectl get --raw "/api/v1/namespaces/$1/services/$2/proxy$3"
}
urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
promql() { # query -> number of series
  svc_get monitoring kube-prometheus-stack-prometheus:9090 "/api/v1/query?query=$(urlencode "$1")" |
    python3 -c 'import sys, json; print(len(json.load(sys.stdin)["data"]["result"]))'
}

section "Cluster"
if kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; then
  pass "node Ready: $(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}')"
else
  fail "node not Ready"
fi
not_ready=$(kubectl -n argocd get applications.argoproj.io --no-headers \
  -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status | grep -v 'Synced *Healthy' || true)
if [[ -z "$not_ready" ]]; then
  pass "Argo CD: $(kubectl -n argocd get applications.argoproj.io --no-headers | wc -l) applications Synced/Healthy"
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

section "Prometheus"
for job in angie-v1 angie-v2; do
  n=$(promql "up{namespace=\"demo\",service=\"${job}\"} == 1")
  check "target ${job} up (${n} series)" between "$n" 1 100
done
n=$(promql 'up{job=~".*envoy.*"} == 1')
check "Envoy targets up (${n})" between "$n" 1 100
n=$(promql 'sum by (code) (rate(angie_http_server_zones_responses{zone="demo"}[5m]))')
check "PromQL: Angie responses by status code (${n} series)" between "$n" 1 100
n=$(promql 'count by (__name__) ({__name__=~"envoy_cluster_upstream_rq_total|node_cpu_seconds_total|kube_pod_status_ready|apiserver_request_total"})')
check "PromQL: Envoy, node-exporter, kube-state-metrics, apiserver metrics (${n}/4)" test "$n" -eq 4

section "Logging (Fluentd -> Loki)"
curl -fsS --max-time 5 -o /dev/null "${HTTP_URL}/?marker=${MARKER}" || true
query=$(urlencode "{namespace=\"demo\"} |= \"${MARKER}\"")
start=$(( $(date +%s) - 300 ))000000000
found=""
for _ in $(seq 1 24); do
  found=$(svc_get logging loki:3100 "/loki/api/v1/query_range?query=${query}&start=${start}&limit=1" |
    python3 -c 'import sys, json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["values"][0][1] if r else "")')
  [[ -n "$found" ]] && break
  sleep 5
done
if [[ -n "$found" ]]; then
  pass "access log for ?marker=${MARKER} found in Loki:"
  echo "      ${found}"
else
  fail "access log with marker ${MARKER} not in Loki after 2 minutes"
fi

echo
if ((failures == 0)); then echo "All checks passed."; else echo "${failures} check(s) failed."; fi
exit "$failures"
