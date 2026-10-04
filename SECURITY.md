# Политика безопасности

## Поддерживаемые версии

Поддерживается только ветка `main`. Релизов с отдельной поддержкой нет.

## Как сообщить об уязвимости

Не создавайте публичный issue. Сообщите через GitHub:
[Security → Report a vulnerability](https://github.com/gifi71/mts-hack-2026/security/advisories/new).

Опишите, что затронуто (файл, компонент, версия), как воспроизвести и к чему это ведёт.
Ответ в течение 7 дней. Исправление выходит коммитом в `main`, после этого публикуется advisory.

## Что уже проверяется автоматически

- секреты в истории git (gitleaks, workflow `security`, и хук pre-commit перед каждым коммитом);
- ошибки конфигурации IaC и Kubernetes (Trivy config, Kubescape), уязвимости образа Fluentd (Trivy);
- CIS Kubernetes Benchmark развёрнутого кластера (kube-bench в e2e);
- подпись образа Fluentd: ставится в CI (cosign keyless), проверяется в кластере (Kyverno);
- безопасность самого репозитория (OpenSSF Scorecard).

Принятые исключения сканеров с обоснованием: [.trivyignore.yaml](.trivyignore.yaml),
[images/fluentd/.trivyignore.yaml](images/fluentd/.trivyignore.yaml), [tests/cis/kube-bench.sh](tests/cis/kube-bench.sh).
