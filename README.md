# MTC ENGINEER HACK 2026: DevOps

[![ci](https://github.com/gifi71/mts-hack-2026/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gifi71/mts-hack-2026/actions/workflows/ci.yml)
[![image-fluentd](https://github.com/gifi71/mts-hack-2026/actions/workflows/image-fluentd.yml/badge.svg?branch=main)](https://github.com/gifi71/mts-hack-2026/actions/workflows/image-fluentd.yml)

Kubernetes-кластер на **kubeadm** с нуля на Ubuntu 24.04 и платформа вокруг демо-приложения:
публикация через **Gateway API** (Envoy Gateway), метрики в **Prometheus**, логи через **Fluentd** в Loki.
Всё ставится одной командой и проверяется второй:

```bash
make deploy    # Ansible: ОС → containerd → kubeadm → Calico → Argo CD → вся платформа через GitOps
make verify    # smoke-тесты: Gateway API, Prometheus, логи в Loki
```

Повторный `make deploy` ничего не меняет (`changed=0`). CI проверяет это на каждом коммите: поднимает кластер на чистом раннере `ubuntu-24.04` (около 11 минут), повторяет развёртывание и запускает `make verify`.

## Содержание

- [Архитектура](#архитектура)
- [Версии](#версии) и [совместимость](#совместимость)
- [Требования](#требования)
- [Развёртывание](#развёртывание)
- [Проверка](#проверка): [приложение и Gateway API](#приложение-и-gateway-api), [мониторинг](#мониторинг), [логи](#логирование)
- [Дополнительные возможности](#дополнительные-возможности)
- [CI/CD](#cicd)
- [Структура репозитория](#структура-репозитория)
- [Ограничения](#ограничения)

## Архитектура

```mermaid
flowchart LR
    user([Пользователь / curl]) -->|"HTTP :30080<br/>HTTPS :30443"| envoy

    subgraph node["Ubuntu 24.04 · Kubernetes 1.36.5 (kubeadm, одна нода) · containerd · Calico"]
        envoy["Envoy proxy<br/>Gateway <b>edge</b><br/>(Envoy Gateway)"]
        envoy -->|"HTTPRoute demo<br/>90% / 10%, header, path"| v1["Angie v1 ×2"]
        envoy --> v2["Angie v2 ×1"]
        envoy -->|HTTPS| ui["Grafana · Prometheus · Argo CD"]

        prom[("Prometheus")] -. scrape .-> v1 & v2 & envoy
        prom -. scrape .-> cp["apiserver, etcd, scheduler,<br/>controller-manager, kubelet,<br/>node-exporter, kube-state-metrics"]
        fluentd["Fluentd DaemonSet"] -->|"/var/log/containers"| loki[("Loki")]
        grafana["Grafana"] --> prom & loki

        argo["Argo CD"] -->|app of apps| envoy & prom & loki & fluentd & v1
    end

    git[("GitHub: этот репозиторий")] --> argo
```

Как идёт развёртывание:

1. **OpenTofu** (опционально) создаёт ВМ Ubuntu 24.04 на Proxmox и пишет Ansible inventory.
2. **Ansible** готовит ОС, ставит containerd, kubeadm, Calico, Helm и Argo CD. Затем создаёт root Application.
3. **Argo CD** синхронизирует `gitops/apps`: Helm-чарт с Application на каждый компонент.
   Порядок задают sync-waves: хранилище и CRD → Prometheus → Envoy Gateway, cert-manager, Loki → Gateway, мониторы, Fluentd → приложение.
4. Ansible ждёт, пока все Application станут `Synced/Healthy`. После этого `make deploy` завершается.

Почему так устроено, описано в [docs/adr](docs/adr).

## Версии

| Компонент | Версия | Как ставится |
|---|---|---|
| Ubuntu | 24.04.5 LTS | ВМ (OpenTofu или вручную) |
| **Kubernetes** | **1.36.5** | kubeadm, kubelet, kubectl из `pkgs.k8s.io` |
| containerd / runc | 2.2.1 / 1.3.4 | пакеты Ubuntu `noble-updates` |
| Calico (CNI) | 3.32.2 | tigera-operator, Helm (Ansible), VXLAN |
| Helm | 3.22.0 | Ansible, бинарник с проверкой sha256 |
| Argo CD | 3.5.3 (чарт 10.9.6) | Helm (Ansible) |
| **Gateway API** | **1.6.1, standard channel** | чарт `gateway-crds-helm` v1.9.2 |
| **Envoy Gateway** | **1.9.2** (Envoy 1.39.1) | Argo CD, чарт завендорен в репозиторий |
| cert-manager | 1.21.2 | Argo CD |
| kube-prometheus-stack | 91.8.2: Prometheus 3.15.0, Operator 0.94.1, Grafana 13.2.3, Alertmanager 0.34.1 | Argo CD |
| Loki | 3.7.8 (чарт 18.13.7, monolithic) | Argo CD |
| **Fluentd** | **1.19.3** + fluent-plugin-grafana-loki 1.3.0 | Argo CD, свой образ `ghcr.io/gifi71/mts-hack-2026/fluentd` |
| Angie (приложение) | 1.12.2 | Argo CD, Kustomize |
| local-path-provisioner | 0.0.37 | Argo CD |
| ansible-core | 2.21.4 | `make deps` в `.venv` |
| OpenTofu | ≥ 1.8 (проверено на 1.12.6), провайдер bpg/proxmox 0.114.0 | опционально |

Все версии зафиксированы: пакеты, чарты, образы (Angie и база Fluentd по digest), коллекции Ansible, провайдеры OpenTofu.

### Совместимость

Версия Kubernetes выбрана как последняя минорная, которую официально поддерживают все компоненты.
Сверено с матрицами проектов на 2 октября 2026.

| Компонент | Версия | Поддерживаемые Kubernetes | 1.37 |
|---|---|---|---|
| Calico | 3.32.2 | 1.34, 1.35, 1.36 ([requirements](https://docs.tigera.io/calico/3.32/getting-started/kubernetes/requirements)) | с Calico 3.33 |
| Argo CD | 3.5.3 | 1.33, 1.34, 1.35, 1.36 ([tested versions](https://argo-cd.readthedocs.io/en/stable/operator-manual/tested-kubernetes-versions/)) | нет |
| cert-manager | 1.21.2 | 1.33, 1.34, 1.35, 1.36 ([releases](https://cert-manager.io/docs/releases/)) | нет |
| Envoy Gateway | 1.9.2, Gateway API 1.6.1 | 1.33, 1.34, 1.35, 1.36 ([matrix](https://gateway.envoyproxy.io/news/releases/matrix/)) | нет |
| kube-state-metrics | 2.20.0 | client-go 1.36 ([matrix](https://github.com/kubernetes/kube-state-metrics#compatibility-matrix)) | нет |
| containerd | 2.2.1 (Ubuntu 24.04) | 1.36 требует 2.2+ ([RELEASES.md](https://github.com/containerd/containerd/blob/main/RELEASES.md#kubernetes-support)) | нужен 2.3+ |

Поэтому **Kubernetes 1.36.5**, хотя уже вышла 1.37.1. Сознательно не обновлены:

- Calico 3.33.0: вышел 1 октября, первый релиз ветки, для 1.36 ничего не добавляет;
- Gateway API 1.6.2: Envoy Gateway 1.9.2 поставляется и тестируется с 1.6.1;
- Fluentd 1.19.4: для него ещё нет образа `fluent/fluentd-kubernetes-daemonset`, на котором построен наш образ.

Версия Kubernetes задаётся одной переменной `k8s_version` в [ansible/group_vars/all/main.yml](ansible/group_vars/all/main.yml).

## Требования

**Узел кластера**: одна ВМ **Ubuntu 24.04**, 4 vCPU, 8 ГБ RAM, 30 ГБ диска, доступ в интернет.
Пользователь с `sudo` без пароля.

**Машина, с которой запускается развёртывание** (можно та же ВМ): `make`, `git`, Python ≥ 3.12 с `venv`, `ssh`.
На Ubuntu 24.04:

```bash
sudo apt-get update && sudo apt-get install -y make git python3-venv
```

Ansible и коллекции `make deploy` ставит сам в `.venv`, их версии зафиксированы.

## Развёртывание

### Вариант 1. Прямо на ВМ (самый короткий)

На чистой Ubuntu 24.04:

```bash
git clone https://github.com/gifi71/mts-hack-2026.git && cd mts-hack-2026
make deploy INVENTORY=ansible/inventory/localhost.yml   # 15-20 минут, в основном скачивание образов
make verify INVENTORY=ansible/inventory/localhost.yml
```

Этот же сценарий выполняет CI на чистом раннере `ubuntu-24.04`.

### Вариант 2. С рабочей машины по SSH

```bash
git clone https://github.com/gifi71/mts-hack-2026.git && cd mts-hack-2026
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
# в hosts.yml: ansible_host (IP ВМ), ansible_user, ansible_ssh_private_key_file
make deploy INVENTORY=ansible/inventory/hosts.yml
make verify INVENTORY=ansible/inventory/hosts.yml
```

### Вариант 3. Создать ВМ на Proxmox через OpenTofu

```bash
cp infra/tofu/proxmox/terraform.tfvars.example infra/tofu/proxmox/terraform.tfvars   # узел, сеть, IP
export PROXMOX_VE_ENDPOINT=https://<pve>:8006/ PROXMOX_VE_API_TOKEN='tofu@pve!mts=<secret>'
make infra-up    # ВМ + ansible/inventory/generated/proxmox.yml + known_hosts с ключом хоста
make deploy      # inventory подхватывается автоматически
make verify
```

Подготовка Proxmox и все параметры: [infra/tofu/README.md](infra/tofu/README.md).

Остальные команды: `make help`.

## Проверка

`make verify` выполняет все проверки ниже на узле и печатает `PASS/FAIL` по каждой.
Пример вывода со стенда автора:

```
== Cluster
PASS  node Ready: v1.36.5
PASS  Argo CD: 11 applications Synced/Healthy
== Gateway API (Envoy Gateway, NodePort http://10.0.1.50:30080)
PASS  Gateway edge Programmed (True)
PASS  curl http://10.0.1.50:30080/ -> 'Hello World! (angie v1)'
PASS  HTTPS with the cert-manager CA -> 'Hello World! (angie v1)'
PASS  header X-Canary: always -> v2 ('Hello World! (angie v2)')
PASS  path /v2/ (rewritten to /) -> v2 ('Hello World! (angie v2)')
PASS  traffic split 90/10: v2 served 10/100 requests
== Prometheus
PASS  target angie-v1 up (2 pods)
PASS  target angie-v2 up (1 pods)
PASS  Envoy targets up (2)
PASS  PromQL angie_http_server_zones_responses{zone="demo"}: 3 series
PASS  PromQL: Envoy, node-exporter, kube-state-metrics, apiserver metrics (4/4)
      Angie responses by code: 200=189
== Logging (Fluentd -> Loki)
PASS  access log for ?marker=verify-1790873478-739 found in Loki:
      {"time":"2026-10-01T16:49:56+00:00","app":"demo","version":"v1",...,"uri":"/?marker=verify-...","status":200,...}
All checks passed.
```

Ниже то же самое руками. Команды `kubectl` выполняются на узле (`make ssh`).

### Приложение и Gateway API

Envoy Gateway публикует Gateway `edge` через NodePort: **HTTP `30080`**, **HTTPS `30443`**.

```bash
NODE=<IP узла>

curl http://$NODE:30080/
# Hello World! (angie v1)

# HTTPS по имени, сертификат выпущен cert-manager из локального CA
make ca-cert    # сохранит mts-hack-ca.crt
curl --cacert mts-hack-ca.crt --resolve app.mts-hack.local:30443:$NODE https://app.mts-hack.local:30443/

# маршрутизация по заголовку и пути
curl -H 'Host: app.mts-hack.local' -H 'X-Canary: always' http://$NODE:30080/   # -> v2
curl -H 'Host: app.mts-hack.local' http://$NODE:30080/v2/                      # -> v2, префикс срезан

# traffic splitting 90/10
for i in $(seq 100); do curl -s -H 'Host: app.mts-hack.local' http://$NODE:30080/; done | sort | uniq -c
```

Ресурсы Gateway API ([gitops/platform/gateway](gitops/platform/gateway), [gitops/workloads/demo-app/httproute.yaml](gitops/workloads/demo-app/httproute.yaml)):

| Ресурс | Что делает |
|---|---|
| `GatewayClass envoy` | контроллер Envoy Gateway, параметры из `EnvoyProxy nodeport` (NodePort 30080/30443) |
| `Gateway edge` | слушатели `http :80` (любой host) и `https :443` (`*.mts-hack.local`, TLS terminate) |
| `HTTPRoute demo` | `app.mts-hack.local`: заголовок `X-Canary: always` → v2; `/v2` → v2 с `URLRewrite`; остальное 90/10; таймаут 5 с; заголовок ответа `X-Served-By` |
| `HTTPRoute demo-default` | без hostname: `curl http://<узел>:30080/` работает без заголовка Host |
| `HTTPRoute https-redirect` | HTTP → HTTPS (301) для Grafana, Prometheus, Argo CD |
| `HTTPRoute grafana / prometheus / argocd` | UI платформы по HTTPS |

Gateway принимает маршруты только из перечисленных namespace (`allowedRoutes` с селектором).

**UI в браузере.** Добавьте в `/etc/hosts` строку `<IP узла> app.mts-hack.local grafana.mts-hack.local prometheus.mts-hack.local argocd.mts-hack.local`
и откройте `https://grafana.mts-hack.local:30443`. Логины и пароли выводит `make credentials`.

### Мониторинг

Prometheus ставится kube-prometheus-stack (Prometheus Operator). Что собирается:

| Источник | Метрики | Как подключено |
|---|---|---|
| Angie | запросы, ответы по кодам, байты, соединения (`angie_http_server_zones_*`, `angie_connections_*`) | встроенный модуль `prometheus` Angie, `ServiceMonitor angie` |
| Envoy (data plane) | RPS, коды ответов, latency по маршрутам (`envoy_cluster_upstream_rq_*`, `envoy_http_downstream_*`) | `PodMonitor envoy-proxy` |
| Envoy Gateway | контроллер | `ServiceMonitor envoy-gateway` |
| Узел | CPU, RAM, диск, сеть | node-exporter |
| Kubernetes | состояние объектов, apiserver, etcd, scheduler, controller-manager, kubelet/cAdvisor, kube-proxy, CoreDNS | kube-state-metrics и мониторы чарта; метрики control plane открыты в конфиге kubeadm |
| Платформа | Argo CD, cert-manager, Fluentd, Calico (Felix) | ServiceMonitor каждого компонента |

Проверка в UI: `https://prometheus.mts-hack.local:30443/targets` или через API на узле:

```bash
q() { kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; }
q 'up{namespace="demo"}'
q 'sum by (code) (rate(angie_http_server_zones_responses{zone="demo"}[5m]))'
q 'sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total[5m]))'
```

Хранение 3 дня (`retention: 3d`, лимит 6 ГБ), том на local-path.

### Логирование

**Fluentd** работает как DaemonSet ([gitops/platform/logging/fluentd.yaml](gitops/platform/logging/fluentd.yaml)):

1. читает `/var/log/containers/*.log` всех подов, формат CRI;
2. добавляет метаданные Kubernetes (namespace, pod, labels);
3. access-лог Angie пишется в JSON, Fluentd разбирает его на поля: `status`, `uri`, `request_time`, `version`, `request_id`;
4. отправляет в **Loki** с метками `namespace`, `pod`, `container`, `app`, `stream`.

Loki хранит логи 3 дня, как и Prometheus. Смотреть логи: Grafana → Explore → Loki, или через API на узле:

```bash
curl -s "http://$NODE:30080/?marker=check-123" >/dev/null
sleep 10
kubectl get --raw '/api/v1/namespaces/logging/services/loki:3100/proxy/loki/api/v1/query_range?query=%7Bnamespace%3D%22demo%22%7D%20%7C%3D%20%22check-123%22&limit=5'
```

LogQL для Grafana: `{namespace="demo", app="angie"} | json | status >= 400`.

## Дополнительные возможности

- **Расширенный Gateway API**: HTTPS с cert-manager, редирект HTTP → HTTPS, маршрутизация по hostname, path и заголовку, rewrite пути, traffic splitting 90/10, таймауты, изменение заголовков ответа, несколько backend.
- **GitOps**: Argo CD, app of apps, sync-waves, self-heal. Изменения в кластер попадают только через git.
- **Идемпотентность доказана**: CI запускает `make deploy` дважды и падает, если второй прогон что-то изменил.
- **Безопасность**:
  - namespace приложения под Pod Security `restricted`;
  - контейнер non-root, read-only root FS, без capabilities, seccomp `RuntimeDefault`;
  - NetworkPolicy default-deny, разрешены только Envoy → приложение и Prometheus → метрики;
  - секреты (пароль Grafana) генерируются при установке и в репозитории не хранятся;
  - host key ВМ закреплён в `known_hosts`, `StrictHostKeyChecking` включён.
- **Цепочка поставки**: свой образ Fluentd собирается в CI. Затем:
  - сканируется Trivy;
  - получает SBOM и SLSA provenance;
  - подписывается cosign (keyless).

  Базовые образы и Angie закреплены по digest. Проверить подпись:

  ```bash
  cosign verify ghcr.io/gifi71/mts-hack-2026/fluentd:v1.19.3-loki1.3.0 \
    --certificate-identity-regexp '^https://github.com/gifi71/mts-hack-2026/.github/workflows/image-fluentd.yml@refs/heads/main$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```
- **Устойчивость к блокировкам реестров**: containerd тянет образы Docker Hub через зеркало `mirror.gcr.io`, чарт Envoy Gateway завендорен, Calico ставится из GitHub Releases.
- **Надёжность приложения**: 3 реплики, readiness и liveness probes, PodDisruptionBudget, rolling update без простоя.
- **Наблюдаемость платформы**: метрики control plane, Argo CD, cert-manager, Fluentd, Calico.

## CI/CD

[.github/workflows](.github/workflows):

| Workflow | Что делает |
|---|---|
| `ci` / lint | yamllint, ansible-lint (профиль `production`), shellcheck, `tofu fmt/validate/test`, helm lint, kubeconform по всем отрендеренным манифестам |
| `ci` / security | gitleaks (секреты в истории), Trivy config scan (IaC, SARIF в Security) |
| `ci` / e2e | чистый раннер `ubuntu-24.04`: `make deploy` с kubeadm, повторный `make deploy` (должен быть `changed=0`), `make verify` |
| `image-fluentd` | сборка образа Fluentd, SBOM, provenance, Trivy, подпись cosign, публикация в ghcr.io |

CD выполняет Argo CD: после merge в `main` кластер приводится к состоянию из git.

## Структура репозитория

```
infra/tofu/           OpenTofu: ВМ на Proxmox, inventory и known_hosts (опционально)
ansible/              роли: node_prep, containerd, kubernetes, helm, kubeadm, calico, platform_secrets, argocd
gitops/apps/          app of apps: Helm-чарт с Argo CD Application на каждый компонент
gitops/platform/      values и манифесты компонентов (gateway, monitoring, logging, cert-manager, ...)
gitops/workloads/     демо-приложение Angie (Kustomize: base + v1/v2)
images/fluentd/       Dockerfile образа Fluentd с плагином Loki
tests/smoke/          verify.sh, запускается через make verify
docs/                 ADR и паспорт решения
```

## Ограничения

- **Одна нода.** Control plane без taint, рабочая нагрузка на нём же. HA нет. Inventory разделён на
  `control_plane` и `workers`, но добавление worker-нод не реализовано и не проверено.
- **NodePort вместо LoadBalancer.** Порты 30080 и 30443 вместо 80 и 443. Так работает в любой сети,
  включая облачные, где нет L2-анонсов для MetalLB.
- **Самоподписанный CA.** Для HTTPS клиенту нужен `mts-hack-ca.crt` (`make ca-cert`) или `curl -k`.
- **Prometheus, Grafana и Argo CD UI** доступны через Gateway любому, кто достаёт до узла. Grafana и Argo CD
  требуют пароль, Prometheus нет. Для стенда допустимо, в проде нужна аутентификация на Gateway (OIDC) или отдельная сеть.
- **Хранилище local-path**: данные Prometheus и Loki живут на диске ноды и пропадают вместе с ней.
- **State OpenTofu** хранится локально.
- **Нужен интернет** на узле: пакеты, образы, чарты и этот репозиторий для Argo CD.
- **Fluentd работает от root.** Ему нужен доступ к `/var/log` ноды, поэтому namespace `logging` не под PSA `restricted`.
