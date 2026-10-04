# 04. Fluentd → Loki, свой образ Fluentd

## Контекст

ТЗ разрешает только Fluentd или Filebeat. Логи нужно хранить и искать, на ноде 8 ГБ RAM.

## Решение

- **Fluentd 1.19** DaemonSet читает `/var/log/containers`, добавляет метаданные Kubernetes,
  разбирает JSON access-лога Angie и пишет в **Loki 3.7** (monolithic, filesystem, 3 дня).
- Метрики и логи смотрятся в одной Grafana.
- Готового DaemonSet-образа с выводом в Loki нет: `grafana/fluent-plugin-loki` не содержит фильтра
  `kubernetes_metadata` и парсера CRI, а у `fluentd-kubernetes-daemonset` нет варианта с Loki.
  Свой образ = официальный `fluentd-kubernetes-daemonset` (по digest) + `fluent-plugin-grafana-loki`.
  Собирается в CI, сканируется Trivy, подписывается cosign.
- Апстрим-образ собран без свежих исправлений Debian (3 CRITICAL и около 25 HIGH на 2026-10-03:
  perl, util-linux, openssl). Сборка делает `apt-get upgrade` из snapshot.debian.org на
  зафиксированную дату (`ARG DEBIAN_SNAPSHOT`). Обычный `upgrade` из живого зеркала даёт другой набор
  пакетов при каждой пересборке, snapshot даёт те же версии. Дата входит в тег образа.
- Trivy стоит до публикации: исправимые HIGH и CRITICAL не дают образу попасть в ghcr.io.
  Исключения с обоснованием в `images/fluentd/.trivyignore.yaml`.

## Варианты

- **Filebeat → Elasticsearch/Kibana**: тяжелее по памяти, лицензии Elastic.
- **Fluentd → OpenSearch**: полнотекстовый поиск, но 2-3 ГБ RAM.
- **VictoriaLogs**: экономнее Loki на больших объёмах. На наших объёмах разница несущественна,
  а Loki с Grafana привычнее проверяющим. Вынесено в развитие.

## Последствия

- Fluentd работает от root (нужен `/var/log` ноды), namespace `logging` не под PSA `restricted`.
- Логи приложения структурированы: в Loki доступны `status`, `uri`, `request_time`, `version`.
- Патчи безопасности базы приходят только при сдвиге `DEBIAN_SNAPSHOT`. Сдвиг делается руками,
  сигнал к нему даёт еженедельный скан в workflow `security`. Образ не побитово воспроизводим
  (временные метки файлов), воспроизводимы версии пакетов и gem.
