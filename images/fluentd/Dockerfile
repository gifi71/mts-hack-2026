# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

# Fluentd DaemonSet image with the Loki output plugin.
# The upstream image already ships tail/CRI parsing and the Kubernetes metadata filter;
# there is no official variant with fluent-plugin-grafana-loki.
FROM docker.io/fluent/fluentd-kubernetes-daemonset:v1.19.3-debian-forward-1.1@sha256:358ec8e09ca57120e557b836de0a586cc51dd6e62e237b5e96612bdb6f7831d9

# Debian packages come from snapshot.debian.org at a fixed point in time. The upgrade
# brings in the security fixes the upstream image was built without, and every rebuild
# gets the same package versions. Move the timestamp forward to take newer fixes.
ARG DEBIAN_SNAPSHOT=20261003T000000Z

# Gems are pinned by version and by the sha256 that rubygems.org publishes for the .gem
# file, and installed with --local: a changed file or a missing dependency fails the build
# instead of pulling something new.
ARG LOKI_PLUGIN_VERSION=1.3.0
ARG LOKI_PLUGIN_SHA256=a9fb5177bbe391da4fb1de434659125e5d39010b67340953742d68d9fddbf86c
# Ruby 3.4.10 bundles resolv 0.7.1 as a default gem (CVE-2026-80212). A newer installed
# version takes precedence on require; CI checks which one is loaded. Its gem builds a
# C extension, so the compiler is installed for the build and purged afterwards.
ARG RESOLV_VERSION=0.7.2
ARG RESOLV_SHA256=626d044d975ab2daac759bf898416f1b51e2cb8dcd6727c2b5b5b28b97ead2e1

# The DaemonSet reads node logs as root, like the upstream image (see .trivyignore).
# hadolint ignore=DL3002,DL3066
USER root
# Quoted heredoc: the shell expands the variables (build args are in its environment),
# not the Dockerfile frontend. Accepted lint findings: apt versions come from the pinned
# snapshot (DL3008); cd instead of WORKDIR keeps the upstream working directory (DL3003);
# gems are local files checked by sha256 (DL3028); apt_opts and build_deps split on
# purpose (SC2086).
# hadolint ignore=DL3003,DL3008,DL3028,SC2086
RUN <<'EOF'
set -eux

rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/debian.sources <<SOURCES
Types: deb
URIs: https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES

apt_opts="-o Acquire::Check-Valid-Until=false"
apt-get $apt_opts update
DEBIAN_FRONTEND=noninteractive apt-get $apt_opts \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  upgrade -y --no-install-recommends
build_deps="gcc make libc6-dev"
apt-get $apt_opts install -y --no-install-recommends $build_deps

cd /tmp
gem fetch fluent-plugin-grafana-loki --version "${LOKI_PLUGIN_VERSION}"
gem fetch resolv --version "${RESOLV_VERSION}"
sha256sum -c - <<SUMS
${LOKI_PLUGIN_SHA256}  fluent-plugin-grafana-loki-${LOKI_PLUGIN_VERSION}.gem
${RESOLV_SHA256}  resolv-${RESOLV_VERSION}.gem
SUMS
gem install --local --no-document "fluent-plugin-grafana-loki-${LOKI_PLUGIN_VERSION}.gem"
gem install --local --no-document "resolv-${RESOLV_VERSION}.gem"

apt-get purge -y --auto-remove $build_deps
apt-get clean
rm -rf /var/lib/apt/lists/* /root/.gem /tmp/*
gem sources --clear-all
EOF

LABEL org.opencontainers.image.source="https://github.com/gifi71/mts-hack-2026" \
      org.opencontainers.image.description="Fluentd v1.19.3 with fluent-plugin-grafana-loki" \
      org.opencontainers.image.licenses="Apache-2.0"
