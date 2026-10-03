# Fluentd DaemonSet image with the Loki output plugin.
# The upstream image already ships tail/CRI parsing and the Kubernetes metadata filter;
# there is no official variant with fluent-plugin-grafana-loki.
FROM docker.io/fluent/fluentd-kubernetes-daemonset:v1.19.3-debian-forward-1.1@sha256:358ec8e09ca57120e557b836de0a586cc51dd6e62e237b5e96612bdb6f7831d9

# Debian packages come from snapshot.debian.org at a fixed point in time. The upgrade
# brings in the security fixes the upstream image was built without, and every rebuild
# gets the same package versions. Move the timestamp forward to take newer fixes.
ARG DEBIAN_SNAPSHOT=20261003T000000Z
ARG LOKI_PLUGIN_VERSION=1.3.0
# Ruby 3.4.10 bundles resolv 0.7.1 as a default gem (CVE-2026-80212). A newer installed
# version takes precedence on require; CI checks which one is loaded. Its gem builds a
# C extension, so the compiler is installed for the build and purged afterwards.
ARG RESOLV_VERSION=0.7.2

USER root
RUN rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* \
 && printf '%s\n' \
      'Types: deb' \
      "URIs: https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" \
      'Suites: trixie trixie-updates' \
      'Components: main' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
      '' \
      'Types: deb' \
      "URIs: https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}" \
      'Suites: trixie-security' \
      'Components: main' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/debian.sources \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Check-Valid-Until=false \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      upgrade -y --no-install-recommends \
 && build_deps="gcc make libc6-dev" \
 && apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends $build_deps \
 && gem install fluent-plugin-grafana-loki --version "${LOKI_PLUGIN_VERSION}" --no-document \
 && gem install resolv --version "${RESOLV_VERSION}" --no-document \
 && apt-get purge -y --auto-remove $build_deps \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && gem sources --clear-all \
 && rm -rf /root/.gem /tmp/*

LABEL org.opencontainers.image.source="https://github.com/gifi71/mts-hack-2026" \
      org.opencontainers.image.description="Fluentd v1.19.3 with fluent-plugin-grafana-loki" \
      org.opencontainers.image.licenses="Apache-2.0"
