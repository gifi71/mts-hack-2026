# 0004. Fluentd → Loki, свой образ Fluentd

## Контекст

ТЗ разрешает только Fluentd или Filebeat. Логи нужно хранить и искать, на ноде 8 ГБ RAM.

## Решение

- **Fluentd 1.19** DaemonSet читает `/var/log/containers`, добавляет метаданные Kubernetes,
  разбирает JSON access-лога Angie и пишет в **Loki 3.7** (monolithic, filesystem, 3 дня).
- Метрики и логи смотрятся в одной Grafana.
- Готового образа Fluentd с выводом в Loki нет. Свой образ = официальный `fluentd-kubernetes-daemonset`
  (по digest) + `fluent-plugin-grafana-loki`. Собирается в CI, сканируется Trivy, подписывается cosign.

## Варианты

- **Filebeat → Elasticsearch/Kibana**: тяжелее по памяти, лицензии Elastic.
- **Fluentd → OpenSearch**: полнотекстовый поиск, но 2-3 ГБ RAM.
- **VictoriaLogs**: экономнее Loki на больших объёмах. На наших объёмах разница несущественна,
  а Loki с Grafana привычнее проверяющим. Вынесено в развитие.

## Последствия

- Fluentd работает от root (нужен `/var/log` ноды), namespace `logging` не под PSA `restricted`.
- Логи приложения структурированы: в Loki доступны `status`, `uri`, `request_time`, `version`.
