#!/usr/bin/env bash
# CIS Kubernetes Benchmark for this node with kube-bench. Run as root on the node:
# CI e2e runs it after make verify, `make cis` runs it over SSH. Any FAIL except the
# accepted ones below exits 1. The report is saved to ./kube-bench.txt.
set -euo pipefail

version=0.16.0
sha256=82dbc7e598740dc9344d41f8ad0b8210d57c4c00bdb2c5f1d8a69a2b98baddcf
# Newest benchmark in kube-bench 0.16 (Kubernetes 1.32-1.34); there is none for 1.36 yet.
benchmark=cis-1.12
# Accepted failures:
#   1.1.12      kubeadm runs etcd as root, there is no etcd user to own the data dir
#   1.2.5       needs kubelet serving certificates signed by the cluster CA
#   1.3.7 1.4.2 controller-manager and scheduler listen on the node IP for Prometheus
skip=1.1.12,1.2.5,1.3.7,1.4.2
report=${KUBE_BENCH_REPORT:-kube-bench.txt}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSLo "$work/kube-bench.tgz" \
  "https://github.com/aquasecurity/kube-bench/releases/download/v${version}/kube-bench_${version}_linux_amd64.tar.gz"
echo "${sha256}  $work/kube-bench.tgz" | sha256sum -c - > /dev/null
tar -xzf "$work/kube-bench.tgz" -C "$work"

"$work/kube-bench" run --config-dir "$work/cfg" --config "$work/cfg/config.yaml" \
  --benchmark "$benchmark" --skip "$skip" > "$report" 2>&1 || true

grep -E "^== Summary total" -A4 "$report"
if grep -E "^\[FAIL\]" "$report"; then
  echo "kube-bench: unexpected CIS failures above (full report: $report)"
  exit 1
fi
echo "kube-bench: no CIS failures outside the accepted list ($skip)"
