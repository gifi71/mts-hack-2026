# Fluentd DaemonSet image with the Loki output plugin.
# The upstream image already ships tail/CRI parsing and the Kubernetes metadata filter;
# there is no official variant with fluent-plugin-grafana-loki.
FROM docker.io/fluent/fluentd-kubernetes-daemonset:v1.19.3-debian-forward-1.1@sha256:358ec8e09ca57120e557b836de0a586cc51dd6e62e237b5e96612bdb6f7831d9

ARG LOKI_PLUGIN_VERSION=1.3.0

USER root
RUN gem install fluent-plugin-grafana-loki --version "${LOKI_PLUGIN_VERSION}" --no-document \
 && gem sources --clear-all \
 && rm -rf /root/.gem /tmp/*

LABEL org.opencontainers.image.source="https://github.com/gifi71/mts-hack-2026" \
      org.opencontainers.image.description="Fluentd v1.19.3 with fluent-plugin-grafana-loki" \
      org.opencontainers.image.licenses="Apache-2.0"
