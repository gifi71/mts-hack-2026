<header class="masthead">
<div>
<h1>Паспорт решения</h1>
<p class="role">MTC ENGINEER HACK 2026 · кейс DevOps</p>
</div>
<p class="meta">github.com/gifi71/mts-hack-2026<br>ветка main<br>автор: Павел Дудко</p>
</header>


## 1. Архитектура и состав решения

| Параметр | Значение |
|---|---|
| Версия Kubernetes | 1.36.5 |
| Способ развёртывания Kubernetes | kubeadm, одна нода (control plane без taint), containerd 2.2, CNI Calico 3.32 (VXLAN) |
| Реализация Gateway API | Envoy Gateway 1.9.2, Gateway API 1.6.1 (standard channel) |
| Инструменты автоматизации | Ansible 2.21 (узел, kubeadm, bootstrap), Argo CD 3.5 (GitOps, app of apps), Helm, Kustomize, OpenTofu (ВМ на Proxmox, опционально), Make |
| Логирование | **Fluentd** 1.19.3 (DaemonSet) → Loki 3.7.8 → Grafana |
| Prometheus | kube-prometheus-stack 91.8.2 (Prometheus Operator) через Argo CD |
| ОС, на которой проверено | Ubuntu 24.04.5 LTS: ВМ на Proxmox и раннер GitHub Actions `ubuntu-24.04` |

![Архитектура](architecture.png)

Запуск: `make deploy`, проверка: `make verify`.

## 2. Реализованный функционал

### Обязательная часть

| Пункт | Как реализован | Почему так | Как проверить |
|---|---|---|---|
| Kubernetes | Ansible-роли: подготовка ОС, containerd, пакеты из pkgs.k8s.io, `kubeadm init` по конфигу v1beta4, Calico | kubeadm в приоритете ТЗ; одна ВМ минимизирует ручные действия эксперта | `make verify` → `node Ready: v1.36.5` |
| Приложение | Angie 1.12.2 (open-source веб-сервер), две версии из одной Kustomize-базы, ответ `Hello World! (angie v1)` | Angie указан в ТЗ, у него встроенные Prometheus-метрики | `curl http://<IP>:30080/` |
| Gateway API | GatewayClass `envoy` + EnvoyProxy (NodePort 30080/30443), Gateway `edge` (HTTP и HTTPS), HTTPRoute | Envoy Gateway: проект Envoy в CNCF, полное соответствие Gateway API, метрики Envoy по маршрутам; NodePort работает в любой сети | `make verify`, раздел Gateway API; `curl -H 'Host: app.mts-hack.local' http://<IP>:30080/v2/` |
| Мониторинг | kube-prometheus-stack, ServiceMonitor/PodMonitor для Angie, Envoy, Argo CD, Calico; метрики control plane | Prometheus Operator: мониторы описываются рядом с компонентом | `make verify`: target-ы `up`, PromQL по `angie_http_server_zones_responses` |
| Логирование | Fluentd DaemonSet: CRI-логи, метаданные Kubernetes, разбор JSON access-лога Angie, error-лог в stderr, отправка в Loki | Fluentd разрешён ТЗ; Loki лёгкий и встраивается в ту же Grafana | `make verify`: строки access- и error-лога с уникальной меткой находятся в Loki |
| Ubuntu 24.04 | проверено на cloud image (ВМ Proxmox) и в CI на `ubuntu-24.04`; пакеты из `noble-updates`, проверка версии ОС в Ansible | тот же образ, что у проверяющих (Ubuntu cloud image); CI даёт публичное подтверждение на каждом коммите | вкладка Actions репозитория |
| Автоматизация | `make deploy`: Ansible от пакетов ОС до Argo CD, дальше Argo CD; повторный запуск ничего не меняет | одна команда от чистой ВМ до рабочей платформы; Ansible идемпотентен, Argo CD сам приводит кластер к состоянию из git | CI: второй `make deploy` обязан дать `changed=0` |

### Дополнительные улучшения

| Что | Как | Зачем | Как проверить |
|---|---|---|---|
| Расширенный Gateway API | HTTPS (cert-manager, свой CA), редирект HTTP→HTTPS, маршруты по hostname, path, заголовку, `URLRewrite`, split 90/10, таймауты, заголовки ответа | показать возможности Gateway API из ТЗ | `make verify`: HTTPS, `X-Canary`, `/v2`, split |
| GitOps | Argo CD, app of apps, sync-waves, self-heal, server-side diff | изменения только через git, дрейф исправляется сам | `argocd.mts-hack.local:30443` |
| CI/CD | `ci`: pre-commit-хуки (yamllint, ansible-lint production, shellcheck, hadolint, actionlint), tofu test, kubeconform, e2e kubeadm на чистой Ubuntu 24.04 с CIS Benchmark (kube-bench); `security`: gitleaks, Trivy IaC и образа, Kubescape (NSA, MITRE) с гейтом на HIGH; OpenSSF Scorecard | проверяет воспроизводимость, идемпотентность и безопасность на каждом коммите с кодом; те же хуки локально (`make hooks`) | Actions → `ci`, `security`, `scorecard`; вкладка Security |
| Цепочка поставки | свой образ Fluentd: патчи Debian из snapshot на фиксированную дату, Trivy до публикации, SBOM, SLSA provenance, подпись cosign; образ и его база по digest | образ собираем сами, значит отвечаем за его происхождение и уязвимости | `cosign verify` (команда в README) |
| Безопасность в кластере | Kyverno: образы репозитория только с подписью cosign из CI (Deny), Audit-политики с PolicyReport; control plane по CIS (audit log, без profiling), 4 принятых исключения; PSA `restricted`, non-root, read-only FS, NetworkPolicy default-deny, секреты генерируются при установке | подпись проверяется при admission, а не только ставится; базовая линия CIS и NSA вместо самодельных правил | `make verify`: неподписанный образ отклонён; `make cis`; `kubectl get policyreport -A` |
| Расширенная наблюдаемость | SLO как код (Sloth): доступность и latency 99%, multi-window burn-rate алерты; дашборды Grafana как код (свой, SLO, Argo CD, Envoy Gateway), алерты (доступность, 5xx, p95, ошибки доставки логов; видны в UI, канал уведомлений не настроен), метрики control plane, структурированные логи, 404/500 в приложении | RPS, коды, latency, CPU/RAM и логи в одном месте | Grafana → «MTS Hack: gateway, app, logs» |
| Меньше внешних зависимостей | зеркало `mirror.gcr.io` для `docker.io` в containerd, завендоренный чарт Envoy Gateway, Calico из GitHub Releases, resolv.conf без чужих search-доменов | Docker Hub и часть реестров нестабильны из РФ | `cat /etc/containerd/certs.d/docker.io/hosts.toml` |
| Провижининг ВМ | OpenTofu: ВМ на Proxmox, cloud-init, inventory, закреплённый host key | цикл «с нуля» одной командой | `make infra-up` |

## 3. Ревью и масштабирование

**Главная особенность.** Решение проверяет само себя. CI на каждом коммите с кодом поднимает kubeadm-кластер на чистой Ubuntu 24.04, разворачивает всю платформу, повторяет развёртывание с требованием `changed=0` и прогоняет те же проверки, что `make verify` у эксперта.

**Самое сложное решение.** Как публиковать Gateway: LoadBalancer с MetalLB или NodePort. MetalLB выглядит «как в проде», но L2-анонсы не работают в облачных сетях, а эксперту пришлось бы подбирать свободные адреса в своей сети. Выбран NodePort с фиксированными портами через EnvoyProxy: он работает на любой ВМ без настройки (ADR 0002).

**Развитие:**

- **HA control plane** (3 ноды + kube-vip) и worker-ноды. Нужны ещё 4+ ВМ, проверка в CI через вложенную виртуализацию.
- **LoadBalancer** через MetalLB (BGP с маршрутизаторами оператора) или внешний балансировщик вместо NodePort. Нужен доступ к сетевому оборудованию.
- **Внешнее хранилище:** S3-совместимое для Loki и Thanos/VictoriaMetrics для долгого хранения метрик. Нужно объектное хранилище.
- **Аутентификация на Gateway** через SecurityPolicy Envoy Gateway и OIDC (Keycloak). Нужен IdP.
- **Kyverno в Enforce** для гигиены workload и проверка подписей сторонних образов (у кого upstream их публикует).
- **Телеком-специфика:**
  - GRPCRoute и TLSRoute для внутренних сервисов;
  - rate limiting на Gateway для защиты от всплесков (Envoy ratelimit + Redis);
  - SLO для каждого сервиса с SLA и маршрутизация алертов в дежурство;
  - мульти-кластер по площадкам (Argo CD ApplicationSet).
- **Kubernetes 1.37** и containerd 2.3 LTS, когда Argo CD, cert-manager и Envoy Gateway добавят 1.37 в свои матрицы (на 2 октября её поддерживает только Calico 3.33). У containerd 2.2 upstream-поддержка заканчивается 6 ноября 2026.
- **VictoriaLogs** вместо Loki при больших объёмах логов.

<footer class="footer">
<span class="links">github.com/gifi71/mts-hack-2026 · make deploy · make verify</span>
<span class="wordmark">PWND<span>.</span>DAY</span>
</footer>
