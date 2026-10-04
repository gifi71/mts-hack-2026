---
status: принято
date: 2026-10-04
deciders: Павел Дудко
related: [ADR-01, ADR-03, ADR-04, ADR-06]
---

# 07. Kyverno для подписи образов, CIS и Kubescape для соответствия

> **Коротко.** В контексте своего образа Fluentd, который CI подписывает cosign, столкнувшись с тем, что
> подпись сама ничего не запрещает, выбрали Kyverno 1.19 с проверкой подписи при admission, kube-bench
> для CIS и Kubescape для манифестов и не стали брать Gatekeeper, policy-controller и встроенный
> ValidatingAdmissionPolicy, чтобы подпись и базовые требования проверялись автоматически, приняв
> около 410 МБ RAM на Kyverno и `failurePolicy: Ignore` на одной ноде.

## Контекст и проблема

Образ Fluentd собираем сами и подписываем cosign в CI (ADR-04). Подпись сама по себе ничего не
запрещает: кластер запустит и неподписанный образ, если его указать в манифесте. Как сделать, чтобы
подпись проверялась при admission, а настройки кластера и манифесты сверялись с общепринятыми базовыми
требованиями, а не только с правилами из AGENTS.md? Решение затрагивает `gitops/platform/kyverno/`,
конфиг kubeadm (`ansible/roles/kubeadm/`), `tests/cis/kube-bench.sh` и workflows `ci` и `security`.

## Требования и ограничения

- Оцениваются базовые практики надёжности и безопасности (docs/task/case.md, критерий 4, 15 баллов).
- Дополнительные практики надёжности и безопасности учитываются при отборе в финал (docs/task/case.md,
  «Возможности для улучшения решения»).
- Одна нода: недоступный admission webhook блокирует создание всех новых подов (ADR-01).
- Новый реестр образов добавляет точку отказа при установке из РФ (ADR-06).
- Kubernetes 1.36: у части инструментов ещё нет официальной поддержки этой версии.

## Рассмотренные варианты

1. Kyverno 1.19, политики на CEL (`policies.kyverno.io`)
2. Kyverno `ClusterPolicy` (`kyverno.io/v1`)
3. OPA Gatekeeper
4. Sigstore policy-controller
5. Встроенный ValidatingAdmissionPolicy

## Решение

Выбран вариант «Kyverno 1.19, политики на CEL», потому что только он одним контроллером проверяет и
подпись cosign, и остальные правила, а классический `ClusterPolicy` в 1.19 объявлен устаревшим.

- **Kyverno 1.19.1** (чарт 3.9.1, `gitops/apps/templates/kyverno.yaml`, sync-wave -1) ставится через
  Argo CD. Политики лежат в `gitops/platform/kyverno/policies`, их Application `kyverno-policies` в
  sync-wave 0.
  - `ImageValidatingPolicy verify-own-images`, `validationActions: [Deny]`: образ из
    `ghcr.io/gifi71/mts-hack-2026/*` допускается только с keyless-подписью cosign. Subject: workflow
    `image-fluentd.yml` на `refs/heads/main`, issuer `https://token.actions.githubusercontent.com`.
    Проверяется подпись digest (`verifyDigest: true`), а не тега.
  - `failurePolicy: Ignore`, таймаут webhook 20 с. На одной ноде падение Kyverno или недоступный Sigstore
    иначе блокировали бы все новые поды. Подпись, которая не сошлась, отклоняется: это результат
    проверки, а не ошибка.
  - Три `ValidatingPolicy` в режиме Audit: `disallow-latest-tag`, `require-requests-limits`,
    `require-probes` (`workload-hygiene.yaml`). Сторонние чарты нам не исправить, поэтому результаты
    идут в PolicyReport, а не блокируют.
  - Образы Kyverno берутся с ghcr.io, а не с `reg.kyverno.io` (`gitops/platform/kyverno/values.yaml`):
    ghcr.io уже нужен для Fluentd, новый реестр не появляется.
- **CIS Kubernetes Benchmark** через kube-bench 0.16.0 (бенчмарк `cis-1.12`). Control plane настроен по
  CIS в `ansible/roles/kubeadm/templates/kubeadm-config.yaml.j2`: `profiling=false` для apiserver,
  controller-manager и scheduler, audit log, `service-account-extend-token-expiration=false`. Права
  `0600` на файлы kubelet задаёт Ansible (`kubeadm_kubelet_restricted_files`). `tests/cis/kube-bench.sh`
  падает на любом FAIL вне списка принятых.
- **Kubescape 4.0.15** (CNCF) проверяет наши отрендеренные манифесты по фреймворкам `nsa` и `mitre`
  (`make kubescape`). В workflow `security` находка уровня HIGH и выше валит job.

### Последствия

- Плюс: неподписанный образ этого репозитория не запустится, даже если его указать в манифесте.
- Плюс: настройки кластера и манифестов сверяются с CIS, NSA и MITRE ATT&CK, а не только с AGENTS.md.
- Минус: около 410 МБ RAM на Kyverno (замер на стенде, лимиты admission controller в values не заданы).
- Минус: application controller Argo CD кэширует CRD Kyverno с большими схемами. Лимит памяти controller
  поднят до 1536Mi (`gitops/platform/argocd/values.yaml`): с 768Mi его убивал OOM при старте.
- Минус: без доступа к Sigstore с ноды поды с образами этого репозитория создаются без проверки
  (`failurePolicy: Ignore`), с задержкой до 20 с на таймаут webhook.
- Минус: Kyverno 1.19.1 официально заявляет Kubernetes 1.33-1.35, kube-bench 0.16 знает бенчмарки до
  1.34. На 1.36 их работу подтверждает только наш e2e.
- Нейтрально: Fluentd перенесён в sync-wave 1, после политик: его под создаётся уже под проверкой подписи.
- Нейтрально: 4 принятых исключения CIS с причинами в `tests/cis/kube-bench.sh` (1.1.12, 1.2.5, 1.3.7,
  1.4.2). Флаги kubeadm действуют с первой установки, на уже поднятом кластере они не меняются.

### Как проверяется

- `make verify`, секция «Admission policies (Kyverno)», server-side dry run пода:
  - «signed Fluentd image admitted»: PASS или FAIL, без допущенного образа Fluentd не стартует;
  - «unsigned image of this repository denied»: артефакт `sha256-<digest>` рядом с подписью должен быть
    отклонён. Если отказа нет (так бывает без Sigstore), печатает WARN, а без ghcr.io с ноды
    проверка пропускается с WARN «unsigned image check skipped»;
  - «PolicyReports for workload policies (N)»: при нуле отчётов WARN.
- CI: workflow `ci`, job e2e, шаг «CIS Kubernetes Benchmark (kube-bench)» после `make verify`, отчёт
  `kube-bench.txt` в артефактах. Локально: `make cis`.
- CI: workflow `security`, job «Kubernetes posture (Kubescape NSA, MITRE)», шаг «Kubescape gate (HIGH,
  CRITICAL)» с `--severity-threshold high`, SARIF во вкладке Security.

## Плюсы и минусы вариантов

### Kyverno `ClusterPolicy` (`kyverno.io/v1`)

- Плюс: работает и в 1.19.
- Минус: в 1.19 объявлен устаревшим.

### OPA Gatekeeper

- Плюс: зрелый проект CNCF.
- Минус: политики на Rego, проверку подписи cosign из коробки не делает.

### Sigstore policy-controller

- Плюс: сделан именно для подписей Sigstore.
- Минус: проверяет только подписи, для остальных политик всё равно нужен второй контроллер.

### Встроенный ValidatingAdmissionPolicy

- Плюс: без отдельного контроллера и памяти под него.
- Минус: CEL без внешних вызовов, проверить подпись в реестре не может.

## Когда пересмотреть

- Kyverno или kube-bench выпускают версию с официальной поддержкой Kubernetes 1.36 или выходит
  CIS-бенчмарк для 1.36.
- Появляется вторая нода или HA Kyverno: можно перейти на `failurePolicy: Fail`.
- Сторонние чарты проходят Audit-политики: их можно перевести в Deny.

## Ссылки

- Код: `gitops/platform/kyverno/`, `gitops/apps/templates/kyverno.yaml`,
  `ansible/roles/kubeadm/templates/kubeadm-config.yaml.j2`, `tests/cis/kube-bench.sh`,
  `tests/smoke/verify.sh`, `.github/workflows/ci.yml`, `.github/workflows/security.yml`
- Связанные ADR: ADR-01, ADR-03, ADR-04, ADR-06
- Требования: [docs/task/case.md](../task/case.md)
- Документация: <https://kyverno.io/docs/>, <https://github.com/aquasecurity/kube-bench>,
  <https://kubescape.io/docs/>
