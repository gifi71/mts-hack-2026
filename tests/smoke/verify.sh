#!/usr/bin/env bash
# Smoke tests for the deployed platform. Runs on the Kubernetes node
# (`make verify` copies and runs it there), needs kubectl, curl and python3.
#
#   1. Cluster and Argo CD applications are healthy
#   2. The app answers through Gateway API: HTTP, HTTPS, header/path routing, traffic split
#   3. Prometheus scrapes the app and the gateway, PromQL returns data
#   4. Access and error log lines with a unique marker show up in Loki (Fluentd pipeline)
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
echo "      Angie responses by code: $({ svc_get monitoring kube-prometheus-stack-prometheus:9090 \
  "/api/v1/query?query=$(urlencode 'sum by (code) (angie_http_server_zones_responses{zone="demo"})')" 2>/dev/null ||
  echo "$EMPTY_RESULT"; } |
  python3 -c 'import sys, json; print(", ".join(r["metric"]["code"] + "=" + r["value"][1] for r in json.load(sys.stdin)["data"]["result"]))')"

section "Logging (Fluentd -> Loki)"
curl -fsS --max-time 5 -o /dev/null "${HTTP_URL}/?marker=${MARKER}" || true
curl -s --max-time 5 -o /dev/null "${HTTP_URL}/missing?marker=${MARKER}" || true

found=$(loki_find "{namespace=\"demo\", stream=\"stdout\"} |= \"${MARKER}\"")
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
if ((failures == 0)); then echo "All checks passed."; else echo "${failures} check(s) failed."; fi
exit "$failures"
