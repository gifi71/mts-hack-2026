---
status: принято
date: 2026-10-04
deciders: Павел Дудко
related: [ADR-01, ADR-03, ADR-06, ADR-07, ADR-09, ADR-10]
---

# 04. Fluentd → Loki, свой образ Fluentd

> **Коротко.** В контексте сбора логов демо-приложения на одной ноде (минимум 8 ГБ RAM), столкнувшись с тем, что ТЗ
> разрешает только Fluentd или Filebeat, а готового DaemonSet-образа Fluentd с выводом в Loki нет, выбрали
> Fluentd в Loki со своим образом, собранным и подписанным в CI, и не стали брать Elasticsearch,
> OpenSearch и VictoriaLogs, чтобы метрики и логи смотрелись в одной Grafana при небольшом расходе памяти,
> приняв поддержку своего образа и Fluentd от root.

## Контекст и проблема

Куда отправлять логи и из какого образа запускать коллектор? Решение затрагивает
`gitops/platform/logging/` (values Fluentd и Loki), `gitops/apps/templates/fluentd.yaml` и `loki.yaml`,
образ `images/fluentd/`, workflow `image-fluentd` и job `image` в workflow `security`.

## Требования и ограничения

- Логи собирает Fluentd или Filebeat, нужны access- и error-логи приложения, после запроса запись должна
  появляться в хранилище (docs/task/case.md, «Логирование»).
- Мониторинг и логирование: 20 баллов, оценивается и качество подхода к observability
  (docs/task/case.md, критерий 3).
- Агрегатор логов в кластере (например, Loki) рядом с Prometheus засчитывается как плюс (docs/task/qa.md).
- Нода одна, минимум 8 ГБ RAM: на ней же control plane, Prometheus, Argo CD и Kyverno (ADR-01).
- Образ демо-приложения должен быть публичным или собираться из материалов репозитория (docs/task/case.md).
  То же правило применено к образу коллектора.

## Рассмотренные варианты

1. Fluentd → Loki, свой образ Fluentd
2. Filebeat → Elasticsearch и Kibana
3. Fluentd → OpenSearch
4. Fluentd → VictoriaLogs

## Решение

Выбран вариант «Fluentd → Loki», потому что Loki ставится одним подом, не требует отдельного UI и
открывается в той же Grafana, что и метрики.

- **Fluentd 1.19.3** DaemonSet (чарт `fluentd` 0.6.0 с fluent.github.io, sync-wave 1, namespace `logging`)
  читает `/var/log/containers/*.log` парсером CRI, добавляет метаданные фильтром `kubernetes_metadata` и
  разбирает JSON access-лога Angie. Конфигурация в `gitops/platform/logging/fluentd.yaml`.
- Выход `@type loki` в `http://loki.logging.svc:3100`. Метки Loki: `namespace`, `pod`, `container`, `app`
  (из `app.kubernetes.io/name`, у приложения `angie`), `stream` и постоянные `cluster`, `collector`.
  Поля access-лога (`status`, `uri`, `request_time`, `version`) остаются в JSON-строке.
- Файловый буфер Fluentd лежит на корневой ФС ноды и ограничен: `total_limit_size 512m`,
  `overflow_action drop_oldest_chunk` вместо 64 ГБ по умолчанию.
- **Loki 3.7.8** (чарт 18.13.7 с grafana-community.github.io, sync-wave -1): monolithic, хранилище filesystem
  на PVC 5Gi (local-path), `retention_period: 72h` (3 дня, как у Prometheus, ADR-09). Старое удаляет
  compactor, API удаления выключен (`deletion_mode: disabled`). Конфигурация в `gitops/platform/logging/loki.yaml`.
- Grafana получает Loki как datasource (`additionalDataSources` в
  `gitops/platform/monitoring/kube-prometheus-stack.yaml`).
- Готового DaemonSet-образа с выводом в Loki нет: `grafana/fluent-plugin-loki` не содержит фильтра
  `kubernetes_metadata` и парсера CRI, а у `fluentd-kubernetes-daemonset` нет варианта с Loki.
  Свой образ (`images/fluentd/Dockerfile`): `fluent/fluentd-kubernetes-daemonset:v1.19.3-debian-forward-1.1`
  по digest плюс `fluent-plugin-grafana-loki` 1.3.0. Gem фиксируются по версии и sha256 и ставятся с
  `--local`. Дополнительно ставится `resolv` 0.7.2 вместо встроенного в Ruby 0.7.1 (CVE-2026-80212).
- Апстрим-образ собран без свежих исправлений Debian (на 2026-10-03: 3 CRITICAL и около 25 HIGH в perl,
  util-linux, openssl). Сборка делает `apt-get upgrade` из snapshot.debian.org на зафиксированную дату
  (`ARG DEBIAN_SNAPSHOT=20261003T000000Z`). Обычный `upgrade` из живого зеркала даёт другой набор пакетов
  при каждой пересборке, snapshot даёт те же версии.
- Тег образа: версии Fluentd и плагина, дата snapshot и хеш контекста сборки
  (`v1.19.3-loki1.3.0-deb20261003-a92b22c`). В values образ закреплён по digest, который подписал cosign.
- Trivy стоит до публикации: исправимые HIGH и CRITICAL не дают образу попасть в ghcr.io.
  Исключения с обоснованием в `images/fluentd/.trivyignore.yaml`. При push образ получает SBOM и
  SLSA provenance и подписывается cosign keyless.

### Последствия

- Плюс: метрики и логи в одной Grafana, хранилище логов занимает один под (около 150 МБ RAM на стенде, лимит 2Gi).
- Плюс: логи приложения структурированы, в Loki по ним работают фильтры LogQL (`| json | status >= 500`).
- Плюс: образ коллектора проверяется Trivy до публикации, его подпись проверяет Kyverno при admission (ADR-07).
- Минус: Fluentd работает от root (нужен `/var/log` ноды), namespace `logging` без PSA `restricted`.
- Минус: патчи безопасности базы приходят только при сдвиге `DEBIAN_SNAPSHOT`. Сдвиг делается руками,
  сигнал к нему даёт еженедельный скан в workflow `security`.
- Минус: Loki на local-path, логи пропадают вместе с нодой.
- Минус: если Loki недоступен дольше, чем заполняется буфер в 512 МБ, старые чанки выбрасываются.
- Нейтрально: образ не побитово воспроизводим (временные метки файлов), воспроизводимы версии пакетов и gem.

### Как проверяется

- `make verify`: «access log (stdout) for ?marker=… found in Loki», «error log (stderr) for /missing?marker=…
  found in Loki», «signed Fluentd image admitted».
- CI: workflow `image-fluentd`, шаги «Check the image» (версия плагина и `Resolv::VERSION`), «Scan image
  with Trivy (fail on fixable HIGH and CRITICAL)» до «Push», затем «Sign image (keyless, GitHub OIDC)».
- CI: workflow `security`, job «deployed Fluentd image (cosign, Trivy)»: «Verify the signature» для образа
  из `gitops/platform/logging/fluentd.yaml` и «Trivy image gate (fixable HIGH, CRITICAL)». По расписанию
  (понедельник, 04:00 UTC) скан только отчитывается в Security tab.

## Плюсы и минусы вариантов

### Filebeat → Elasticsearch и Kibana

- Плюс: полнотекстовый поиск, привычный стек.
- Минус: Elasticsearch тяжелее по памяти, лицензии Elastic.

### Fluentd → OpenSearch

- Плюс: полнотекстовый поиск, открытая лицензия.
- Минус: 2-3 ГБ RAM, на ноде с минимальными 8 ГБ это слишком много.

### Fluentd → VictoriaLogs

- Плюс: экономнее Loki на больших объёмах.
- Минус: на наших объёмах разница несущественна, а Loki с Grafana привычнее проверяющим.

## Когда пересмотреть

- Объём логов растёт настолько, что Loki на filesystem не справляется: object storage или VictoriaLogs.
- В апстриме появляется образ `fluentd-kubernetes-daemonset` с выводом в Loki.
- Появляется вторая нода: Loki на local-path перестаёт подходить.

## Ссылки

- Код: `images/fluentd/Dockerfile`, `images/fluentd/.trivyignore.yaml`, `gitops/platform/logging/`,
  `.github/workflows/image-fluentd.yml`, `.github/workflows/security.yml`
- Связанные ADR: ADR-01, ADR-03, ADR-06, ADR-07, ADR-09, ADR-10
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://github.com/fluent/fluentd-kubernetes-daemonset>,
  <https://grafana.com/docs/loki/latest/operations/storage/retention/>, <https://snapshot.debian.org/>
