# 0007. Kyverno для подписи образов, CIS и Kubescape для соответствия

## Контекст

Образ Fluentd собираем сами и подписываем cosign в CI (ADR 0004). Подпись сама по себе ничего не
запрещает: кластер запустит и неподписанный образ, если его указать в манифесте. Нужно, чтобы
подпись проверялась при admission, и чтобы настройки кластера и манифестов сверялись с
общепринятыми базовыми требованиями, а не только с нашими правилами из AGENTS.md.

## Решение

- **Kyverno 1.19** (CNCF) ставится через Argo CD. Политики в новом формате на CEL
  (`policies.kyverno.io`), классический `ClusterPolicy` в 1.19 объявлен устаревшим.
  - `ImageValidatingPolicy verify-own-images`, режим Deny: образ из `ghcr.io/gifi71/mts-hack-2026/*`
    допускается только с keyless-подписью cosign, где identity это workflow `image-fluentd` на `main`,
    а issuer GitHub OIDC. Проверяется подпись digest, а не тега.
  - `failurePolicy: Ignore`. На одной ноде падение Kyverno или недоступный Sigstore иначе блокировали бы
    все новые поды. Подпись, которая не сошлась, всё равно отклоняется: это результат проверки, а не ошибка.
  - Три `ValidatingPolicy` в режиме Audit: pinned-теги, requests/limits, probes. Сторонние чарты нам
    не исправить, поэтому результаты идут в PolicyReport, а не блокируют.
  - Образы Kyverno берутся с ghcr.io, а не с `reg.kyverno.io`: новый реестр в зависимостях не появляется.
- **CIS Kubernetes Benchmark** через kube-bench. Control plane настроен по CIS в конфиге kubeadm
  (profiling, audit log, срок токенов service account), права файлов kubelet задаёт Ansible.
  kube-bench запускается в e2e на чистом кластере и падает на любом FAIL вне списка принятых.
- **Kubescape** (CNCF) проверяет наши отрендеренные манифесты по NSA hardening guide и MITRE ATT&CK
  в workflow `security`, HIGH валит job.

## Варианты

- **OPA Gatekeeper**: политики на Rego, проверку подписи cosign из коробки не делает.
- **Sigstore policy-controller**: проверяет только подписи, для остальных политик всё равно нужен второй контроллер.
- **Kyverno ClusterPolicy (`kyverno.io/v1`)**: работает, но в 1.19 устарел.
- **Встроенный ValidatingAdmissionPolicy**: CEL без внешних вызовов, проверить подпись в реестре не может.

## Последствия

- Kyverno 1.19 официально заявляет Kubernetes 1.33-1.35. На 1.36 его работу проверяет `make verify`
  в e2e: подписанный образ допускается, неподписанный артефакт того же репозитория отклоняется.
- Около 410 МБ RAM на Kyverno. Application controller Argo CD кэширует CRD Kyverno с большими
  схемами, лимит памяти controller поднят до 1536Mi: с 768Mi его убивал OOM при старте.
- Fluentd перенесён в sync-wave 1, после политик: его под создаётся уже под проверкой подписи.
- CIS: 4 принятых исключения с причинами в `tests/cis/kube-bench.sh`. Флаги kubeadm действуют
  с первой установки, на уже поднятом кластере они не меняются.
