---
status: принято
date: 2026-10-04
deciders: Павел Дудко
related: [ADR-02, ADR-03, ADR-04, ADR-07]
---

# 06. Установка при недоступных реестрах и чужом DNS

> **Коротко.** В контексте установки на ВМ эксперта, скорее всего в РФ, столкнувшись с нестабильным
> Docker Hub, медленным Helm-репозиторием Calico и чужим search-доменом в DNS, выбрали зеркало `mirror.gcr.io`
> для `docker.io` в containerd, вендоринг чарта Envoy Gateway, Calico из GitHub Releases, resolv.conf для
> kubelet без search-доменов и необязательный файл зеркал, и не стали делать офлайн-установку и прокси,
> чтобы установка по умолчанию шла без настройки, приняв, что в сети с заблокированным CDN Docker Hub
> эксперту нужно своё зеркало.

## Контекст и проблема

Установка тянет пакеты, образы и чарты из интернета. Docker Hub ограничивает анонимные загрузки и из
части российских сетей недоступен. На стенде автора при разработке нашлись ещё две проблемы окружения:
Helm-репозиторий Calico отдавал ~0.4 КБ/с, а search-домен от DHCP с wildcard-записью ломал DNS в подах.
Как сделать, чтобы установка проходила в чужой сети без ручных шагов? Решение затрагивает роли
`containerd`, `helm`, `calico`, `kubeadm`, values чартов в `gitops/platform/` и `ansible/mirrors.example.yml`.

## Требования и ограничения

- Решение воспроизводится экспертом на своей инфраструктуре (docs/task/case.md, «Kubernetes-окружение»).
- Образ должен быть публично доступен (docs/task/case.md, «Демонстрационное веб-приложение»).
- У проверяющих есть интернет, офлайн-установка не требуется (docs/task/qa.md).
- Зеркало или прокси реестров задать можно, лучше указать (docs/task/qa.md).
- Из РФ без VPN у участника не работали Docker Hub, `get.helm.sh`, `registry.k8s.io`, `ghcr.io`,
  `mirror.gcr.io`, чарты на `*.github.io`; доступность зависит от провайдера (docs/task/qa.md).
- Никаких адресов и имён из лаборатории автора в коде (AGENTS.md, правило 3).

## Рассмотренные варианты

1. Зеркало для `docker.io` в containerd, вендоринг и точечные переопределения образов, свои зеркала через файл
2. Образы и чарты как есть, из реестров по умолчанию
3. Офлайн-установка: образы и чарты в архиве или локальном реестре
4. Прокси (`HTTPS_PROXY`) для containerd, apt и Argo CD

## Решение

Выбран вариант «зеркало и вендоринг», потому что он работает без настройки там, где интернет есть
(требование Q&A), и даёт эксперту одну точку, чтобы подставить свои зеркала.

- **Docker Hub через зеркало.** containerd получает `/etc/containerd/certs.d/docker.io/hosts.toml`:
  сначала `mirror.gcr.io`, потом `registry-1.docker.io` (`containerd_registry_hosts` в
  `ansible/roles/containerd/defaults/main.yml`, шаблон `hosts.toml.j2`). Так тянутся Envoy,
  Envoy Gateway, Grafana, Loki, local-path-provisioner, busybox и Redis для Argo CD.
- **Образы переопределены только там, где дефолт вне этих реестров или плавающий:**
  - Redis для Argo CD: `docker.io/library/redis:8.6.4-alpine` вместо ECR Public
    (`gitops/platform/argocd/values.yaml`);
  - busybox для local-path-provisioner: `1.37.0` вместо `latest`
    (`gitops/platform/local-path-provisioner/values.yaml`);
  - sidecar Loki: с Docker Hub на `quay.io` (`gitops/platform/logging/loki.yaml`);
  - Kyverno: `ghcr.io` вместо `reg.kyverno.io`, новый реестр не появляется (`gitops/platform/kyverno/values.yaml`).
- **Чарты Envoy Gateway завендорены** в `gitops/platform/envoy-gateway/charts/`: они публикуются только как
  OCI-артефакты на Docker Hub. Версия и digest в `charts/README.md`.
- **Calico из GitHub Releases** вместо Helm-репозитория `docs.tigera.io` (`calico_release_url` в
  `ansible/roles/calico/defaults/main.yml`).
- **resolv.conf для kubelet без search-доменов.** При `ndots:5` под резолвил `github.com` как
  `github.com.<search-домен>`, wildcard-запись отвечала чужим адресом, и Argo CD не мог скачать репозиторий.
  Роль `kubeadm` берёт upstream-серверы из `/run/systemd/resolve/resolv.conf` и пишет
  `/etc/kubernetes/resolv.conf` только с ними (`resolvConf` в конфиге kubelet). Поды получают кластерные
  search-домены и эти серверы.
- **Повторы загрузок.** Скачивание Helm и установка чартов Calico и Argo CD повторяются 3 раза
  (`retries: 3` в ролях `helm`, `calico`, `argocd`): GitHub Releases отдавал 503. Argo CD повторяет
  синхронизацию до 10 раз с backoff до 3 минут (`gitops/apps/templates/_helpers.tpl`).
- **Свои зеркала.** Зеркала для `registry.k8s.io`, `ghcr.io`, `quay.io`, `docker.angie.software` и адрес
  загрузки Helm задаются файлом по образцу `ansible/mirrors.example.yml`:
  `make deploy ANSIBLE_ARGS="-e @ansible/mirrors.yml"`. По умолчанию их нет. sha256 Helm проверяется и с зеркала.
- Остальные образы берутся с `registry.k8s.io`, `quay.io`, `ghcr.io`, `docker.angie.software`.

### Последствия

- Плюс: при ограничениях Docker Hub (rate limit, сбои) образы `docker.io` приходят из `mirror.gcr.io`
  без настройки.
- Плюс: чарты Envoy Gateway и Calico ставятся без Docker Hub и `docs.tigera.io`.
- Плюс: поды резолвят внешние имена одинаково в любой сети, независимо от search-домена хоста.
- Минус: `mirror.gcr.io` это pull-through-кэш. Слои, которых в нём нет, он перенаправляет на CDN Docker Hub.
  В сети, где этот CDN заблокирован, настройка containerd не помогает даже с `mirror.gcr.io` единственным хостом
  (проверено 2026-10-03). Нужно своё зеркало, которое отдаёт слои само (Harbor или `registry:2` в режиме proxy
  за VPN), и его адрес в `mirrors.yml`.
- Минус: прокси (`HTTPS_PROXY`) для containerd, apt и Argo CD не сделан. Чарты с `*.github.io`,
  `charts.jetstack.io`, релизы Calico на `github.com` и сам репозиторий качаются напрямую.
- Минус: при обновлении Envoy Gateway чарты нужно перевендорить (`helm pull ... --untar`, команды
  в `charts/README.md`).
- Нейтрально: с недоступным зеркалом containerd 2.2 переходил на `registry.k8s.io`, но загрузка слоёв с `quay.io`
  зависала (проверено 2026-10-03). В `mirrors.yml` перечисляются только рабочие зеркала.

### Как проверяется

- CI: workflow `ci`, job «e2e on a clean Ubuntu 24.04 (kubeadm)»: `make deploy` с зеркалом по умолчанию, все
  образы `docker.io` идут через `hosts.toml`, затем `make verify` (Argo CD: все Application Synced/Healthy).
- `make verify`: «Argo CD: N applications Synced/Healthy» косвенно подтверждает, что Argo CD скачал репозиторий
  и все образы.
- Вручную на ноде: `cat /etc/containerd/certs.d/docker.io/hosts.toml`, `cat /etc/kubernetes/resolv.conf`.
- Автоматической проверки установки через свои зеркала из `mirrors.example.yml` и через заблокированный
  Docker Hub нет.

## Плюсы и минусы вариантов

### Образы и чарты как есть

- Плюс: меньше кода, values чартов по умолчанию.
- Минус: зависимость от Docker Hub без запасного пути, ECR Public для Redis, плавающий `latest` у busybox.

### Офлайн-установка

- Плюс: не зависит от сети эксперта.
- Минус: архив образов на несколько гигабайт, отдельный процесс обновления. По Q&A не требуется.

### Прокси для containerd, apt и Argo CD

- Плюс: закрывает все источники разом, включая чарты и GitHub.
- Минус: эксперту нужен свой прокси, без него вариант ничего не даёт. Не реализован.

## Когда пересмотреть

- Эксперты сообщают, что `mirror.gcr.io` или CDN Docker Hub недоступны в их сети.
- Envoy Gateway начинает публиковать чарты вне Docker Hub.
- `docs.tigera.io` снова отдаёт чарты с нормальной скоростью.

## Ссылки

- Код: `ansible/roles/containerd/`, `ansible/mirrors.example.yml`,
  `ansible/roles/kubeadm/templates/resolv.conf.j2`, `ansible/roles/calico/defaults/main.yml`,
  `gitops/platform/envoy-gateway/charts/README.md`
- Связанные ADR: ADR-02, ADR-03, ADR-04, ADR-07
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://github.com/containerd/containerd/blob/main/docs/hosts.md>,
  <https://cloud.google.com/artifact-registry/docs/pull-cached-dockerhub-images>
