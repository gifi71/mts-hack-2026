---
status: принято
date: 2026-10-02
deciders: Павел Дудко
related: [ADR-01, ADR-02, ADR-04, ADR-06, ADR-07, ADR-08, ADR-09, ADR-11]
---

# 03. Ansible до CNI и Argo CD, дальше GitOps (app of apps)

> **Коротко.** В контексте платформы из десятка компонентов с зависимостями между ними, столкнувшись с
> требованием идемпотентного развёртывания без ручного создания ресурсов, выбрали Ansible для узла,
> kubeadm, Calico и Argo CD, а всё остальное через Argo CD app-of-apps с sync-waves, и не стали брать
> helmfile, чистый Ansible + Helm и отдельный GitOps-репозиторий, чтобы кластер сам держал состояние из
> git и исправлял дрейф, приняв зависимость узла от доступа к GitHub.

## Контекст и проблема

Чем ставить платформу поверх кластера и как задать порядок установки? Компоненты зависят друг от друга:
CRD до ресурсов, cert-manager до сертификатов, Prometheus Operator до ServiceMonitor. Повторный запуск не
должен ломать состояние. Решение затрагивает роль `ansible/roles/argocd`, чарт `gitops/apps` и values
компонентов в `gitops/platform/`.

## Требования и ограничения

- Эксперт получает рабочее решение без ручного создания и редактирования Kubernetes-ресурсов, повторный
  запуск не приводит систему в некорректное состояние ([docs/task/case.md](../task/case.md),
  «Автоматизация развертывания»).
- Оцениваются идемпотентность, повторяемость и управление конфигурацией и зависимостями
  ([docs/task/case.md](../task/case.md), критерий 2, 25 баллов).
- Автоматизировать нужно всё от чистой ВМ до кластера ([docs/task/qa.md](../task/qa.md)).
- Подам нужна сеть до того, как Argo CD сможет запуститься: CNI ставится не через Argo CD.

## Рассмотренные варианты

1. Ansible до Argo CD, дальше Argo CD app-of-apps с sync-waves
2. helmfile
3. Только Ansible + Helm
4. Argo CD с отдельным репозиторием для GitOps

## Решение

Выбран вариант «Ansible до Argo CD, дальше app-of-apps», потому что только он исправляет дрейф без
повторного прогона плейбука и при этом обходится одним репозиторием.

- Ansible (`ansible/site.yml`) делает то, без чего нет кластера: ОС, containerd, kubeadm,
  Calico 3.32.2 (ADR-08), Helm, Secret с паролем Grafana (`platform_secrets`, ADR-11),
  Argo CD 3.5.3 (чарт 10.9.6 через `kubernetes.core.helm`) и root Application
  (`ansible/roles/argocd/templates/root-app.yaml.j2`).
- Root Application синхронизирует `gitops/apps`: Helm-чарт с Application на каждый компонент. У всех
  дочерних Application `prune`, `selfHeal`, retry и `ServerSideApply` (`gitops/apps/templates/_helpers.tpl`).
- Порядок задают sync-waves: -3 CRD Gateway API и local-path-provisioner, -2 kube-prometheus-stack,
  -1 cert-manager, Envoy Gateway, Loki, Kyverno, 0 Gateway, конфигурация мониторинга и политики Kyverno,
  1 Fluentd и приложение. Health дочерних Application включён в `argocd-cm`, поэтому волна ждёт
  готовности предыдущей.
- Values Argo CD лежат в `gitops/platform/argocd/values.yaml`, их читает Ansible при установке.
- Ansible ждёт `Synced/Healthy` всех Application (до 30 минут, `argocd_wait_retries`), поэтому
  `make deploy` завершается рабочей платформой.
- Репозиторий и ревизия задаются переменными `gitops_repo_url` и `gitops_revision`
  (`ansible/group_vars/all/main.yml`).

### Последствия

- Плюс: self-heal. Ручные правки в кластере откатываются к состоянию из git.
- Плюс: `make deploy` идемпотентен целиком: второй прогон даёт `changed=0`.
- Нейтрально: найдены и исправлены две особенности Argo CD 3.x, обе в `gitops/platform/argocd/values.yaml`:
  - чарт по умолчанию игнорирует обновления `/status`, из-за этого health замерзал и волны не
    продвигались. Задано `resource.ignoreResourceUpdatesEnabled: "false"`;
  - клиентский diff не знает дефолтов CRD Gateway API и показывал вечный OutOfSync. Включён
    `controller.diff.server.side`.
- Минус: узлу нужен доступ к GitHub, Argo CD тянет репозиторий оттуда.
- Нейтрально: Argo CD не управляет сам собой. Его версия и values меняются повторным `make deploy`.
- Нейтрально: CI проверяет конкретный коммит через `-e gitops_revision=<sha>`.

### Как проверяется

- `make verify`: «Argo CD: N applications Synced/Healthy».
- CI: workflow `ci`, job «e2e on a clean Ubuntu 24.04 (kubeadm)»: шаг `make deploy` с
  `gitops_revision=${{ github.sha }}`, шаг «make deploy again (idempotency)» с проверкой
  `changed=0 failed=0`, затем `make verify`.
- CI: job «lint and validate», шаг «Render and validate Kubernetes manifests»: рендер `gitops/apps` и
  компонентов, kubeconform.

## Плюсы и минусы вариантов

### helmfile

- Плюс: проще и детерминированнее, порядок явный.
- Минус: нет self-heal и истории изменений в кластере.

### Только Ansible + Helm

- Плюс: один инструмент.
- Минус: каждое изменение требует прогона плейбука, дрейф не исправляется.

### Отдельный репозиторий для GitOps

- Плюс: нужен, когда CI приложения обновляет теги образов.
- Минус: здесь приложение не собирается, второй репозиторий только добавит шагов эксперту.

## Когда пересмотреть

- Появляется своё приложение, CI которого обновляет теги образов: GitOps выносится в отдельный репозиторий.
- Несколько кластеров: root Application заменяется на ApplicationSet.

## Ссылки

- Код: `ansible/site.yml`, `ansible/roles/argocd/`, `gitops/apps/`, `gitops/platform/argocd/values.yaml`
- Связанные ADR: ADR-01, ADR-02, ADR-04, ADR-06, ADR-07, ADR-08, ADR-09, ADR-11
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/>,
  <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/>
