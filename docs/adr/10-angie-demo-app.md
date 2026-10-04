---
status: принято
date: 2026-10-04
deciders: Павел Дудко
related: [ADR-02, ADR-04, ADR-06, ADR-07, ADR-09]
---

# 10. Angie как демо-приложение

> **Коротко.** В контексте демо-приложения, которое должно отвечать по HTTP, писать access-логи и отдавать
> метрики, столкнувшись с тем, что своё приложение баллов не даёт, выбрали Angie из официального образа
> с встроенными метриками Prometheus и JSON-логом в stdout и не стали брать nginx, Apache httpd и своё
> приложение, чтобы получить логи и метрики одним контейнером без сайдкаров и сборки образа, приняв
> отечественный форк nginx, который проверяющий знает хуже.

## Контекст и проблема

Нужен простой веб-сервер, на котором видна вся платформа: маршруты Gateway API, метрики в Prometheus,
логи в Loki. Какое приложение взять и как получить из него две версии для splitting без своей сборки?
Решение затрагивает `gitops/workloads/demo-app/` и проверки в `tests/smoke/verify.sh`.

## Требования и ограничения

- Приложение принимает HTTP, отвечает однозначно проверяемым ответом (например, Hello World!) и пишет
  access-логи для Fluentd или Filebeat (docs/task/case.md, «Демонстрационное веб-приложение»).
- Образ публичный или собирается из материалов репозитория. Своё приложение баллов не даёт
  (docs/task/case.md, там же).
- Эксперт открывает приложение по имени из Gateway API, в том числе в браузере, и смотрит логи Fluentd и
  метрики Prometheus (docs/task/qa.md).
- AGENTS.md: requests/limits, probes, securityContext (`runAsNonRoot`, `readOnlyRootFilesystem`,
  drop `ALL`), namespace под PSA `restricted` и закрыт NetworkPolicy по умолчанию.
- Docker Hub из РФ работает нестабильно (AGENTS.md, ADR-06): образ лучше брать вне него.

## Рассмотренные варианты

1. Angie
2. nginx
3. Apache httpd
4. Своё приложение

## Решение

Выбран вариант «Angie», потому что только он из готовых серверов отдаёт метрики Prometheus сам, без
exporter-сайдкара, и ставится из реестра вне Docker Hub.

- Образ `docker.angie.software/angie:1.12.2-minimal`, закреплён по digest
  (`gitops/workloads/demo-app/base/deployment.yaml`).
- Конфигурация в `base/config/angie.conf`:
  - порт 8080: `/` отвечает `Hello World! (angie <версия>)` с заголовком `X-App-Version`, `/healthz`
    для проб без записи в лог, `/missing` даёт 404 и строку в error-логе, `/error` отвечает 500;
  - access-лог в JSON в stdout (`time`, `version`, `method`, `uri`, `status`, `request_time` и другие
    поля), error-лог в stderr;
  - порт 9113: `/metrics` встроенным модулем `prometheus all`, `status_zone demo` на сервере 8080.
- Две версии из одного base через Kustomize: `overlays/v1` и `overlays/v2` добавляют суффикс, метку
  `app.kubernetes.io/version` и свой `version.conf` с `$app_version`. v1 в 2 репликах, v2 в 1.
  Splitting 90/10 и маршруты по header и path описаны в ADR-02.
- Под: `runAsNonRoot` (uid 100, пользователь `angie` в образе), `readOnlyRootFilesystem`, drop `ALL`,
  seccomp `RuntimeDefault`, без токена service account. Запись только в emptyDir `/tmp`,
  `/var/log/angie`, `/var/cache/angie`. Readiness и liveness на `/healthz`, `preStop` sleep 5 с,
  rolling update с `maxUnavailable: 0`, PDB.
- Namespace `demo` под PSA `restricted`. NetworkPolicy: всё закрыто, вход на `http` только от подов
  Envoy, на `metrics` только от Prometheus, выход закрыт.
- Метрики собирает `ServiceMonitor angie` (порт `metrics`, раз в 15 с).

### Последствия

- Плюс: метрики Angie (запросы, ответы по кодам, соединения) без сайдкара и без своей сборки образа.
- Плюс: JSON access-лог разбирается в Fluentd на поля без регулярных выражений (ADR-04).
- Плюс: v1 и v2 различаются только ConfigMap, поэтому splitting проверяется по телу ответа.
- Минус: Angie известен меньше nginx. Директивы конфигурации совпадают с nginx, отличается модуль метрик.
- Минус: `status_zone demo` считает и пробы kubelet (около 1 rps). SLI и алерт 5xx поэтому считаются по
  метрикам Envoy (ADR-09).
- Нейтрально: `/missing` и `/error` нужны только для проверки логов и панелей 4xx/5xx. Каждый
  `make verify` вызывает `/error` и немного тратит бюджет доступности.

### Как проверяется

- `make verify`, раздел «Gateway API»: «curl http://<IP>:30080/ -> 'Hello World! (angie v1)'»,
  «header X-Canary: always -> v2», «traffic split 90/10», ответы 404 на `/missing` и 500 на `/error`.
- `make verify`, раздел «Prometheus»: «target angie-v1 up», «target angie-v2 up»,
  «PromQL angie_http_server_zones_responses{zone="demo"}».
- `make verify`, раздел «Logging»: access-лог (stdout) и error-лог (stderr) с маркером запроса находятся
  в Loki.
- Политики Kyverno в режиме Audit (pinned-теги, requests/limits, probes) пишут PolicyReport и по подам
  `demo` (ADR-07).

## Плюсы и минусы вариантов

### Angie

- Плюс: встроенные метрики Prometheus и API статистики.
- Плюс: официальный реестр `docker.angie.software`, не Docker Hub.
- Минус: меньше распространён, чем nginx.

### nginx

- Плюс: знаком любому проверяющему.
- Минус: в OSS-версии только `stub_status` из нескольких счётчиков, для метрик Prometheus нужен
  exporter-сайдкар.
- Минус: официальный образ на Docker Hub.

### Apache httpd

- Плюс: зрелый и известный сервер.
- Минус: метрики тоже через отдельный exporter, JSON-лог настраивается сложнее.

### Своё приложение

- Плюс: любые метрики и ответы.
- Минус: нужна сборка и публикация образа, а баллов это не даёт (docs/task/case.md).

## Когда пересмотреть

- Проверяющие или условия требуют приложение с бизнес-логикой или базой данных.
- `docker.angie.software` становится недоступен: образ переносится в своё зеркало (ADR-06).

## Ссылки

- Код: `gitops/workloads/demo-app/`, `gitops/workloads/demo-app/base/config/angie.conf`,
  `tests/smoke/verify.sh`
- Связанные ADR: ADR-02, ADR-04, ADR-06, ADR-07, ADR-09
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://angie.software/en/configuration/modules/http/http_prometheus/>
