---
status: принято
date: 2026-10-04
deciders: Павел Дудко
related: [ADR-02, ADR-03, ADR-04]
---

# 09. kube-prometheus-stack и SLO как код (Sloth)

> **Коротко.** В контексте обязательного мониторинга на Prometheus на одной ноде, столкнувшись с требованием
> показать реально собираемые метрики и желанием мерить качество сервиса, а не только `up`, выбрали
> kube-prometheus-stack (Prometheus Operator) и SLO, сгенерированные Sloth в CI, и не стали брать голый
> Prometheus, VictoriaMetrics, Pyrra и ручные правила, чтобы метрики, алерты, дашборды и SLO описывались
> ресурсами в git, приняв около 4 ГБ лимита памяти на Prometheus и окно SLO, урезанное хранением до 3 дней.

## Контекст и проблема

Как поставить Prometheus, подключить к нему компоненты платформы и показать эксперту не только сбор
метрик, но и их смысл? Компоненты лежат в разных namespace и ставятся разными чартами, у многих есть свои
ServiceMonitor. Решение затрагивает `gitops/platform/monitoring/` (values, правила, SLO, дашборды) и
мониторы в `gitops/workloads/demo-app/` и `gitops/platform/*/values.yaml`.

## Требования и ограничения

- Prometheus получает метрики хотя бы от одного компонента, target доступен, получение показывается
  PromQL-запросом, в README описано, что собирается ([docs/task/case.md](../task/case.md), «Мониторинг»).
- Оцениваются корректность Prometheus, реально собираемые метрики и качество подхода к observability
  ([docs/task/case.md](../task/case.md), критерий 3, 20 баллов).
- Дополнительно учитываются HTTP-метрики, коды ответов, latency, CPU/RAM и дашборды
  ([docs/task/case.md](../task/case.md), «Расширенные мониторинг и логирование»).
- Агрегаторы метрик и логов в кластере засчитываются как плюс ([docs/task/qa.md](../task/qa.md)).
- Всё в кластере описано в `gitops/` и ставится Argo CD (ADR-03). Нода одна, хранилище local-path.

## Рассмотренные варианты

1. kube-prometheus-stack (Prometheus Operator, Grafana, Alertmanager, node-exporter, kube-state-metrics)
2. Голый Prometheus из чарта `prometheus-community/prometheus`
3. VictoriaMetrics (`victoria-metrics-k8s-stack`)

Для SLO:

1. Sloth: спецификация в git, правила генерируются `make slo`, контроллера в кластере нет
2. Pyrra: контроллер в кластере и свой UI
3. Recording rules и burn-rate алерты вручную

## Решение

Выбраны kube-prometheus-stack и Sloth, потому что оператор подхватывает ServiceMonitor и PrometheusRule из
любого namespace, а Sloth даёт стандартные multi-window multi-burn-rate правила без лишнего пода.

- **kube-prometheus-stack 91.8.2** (`gitops/apps/templates/kube-prometheus-stack.yaml`, sync-wave -2: его CRD
  ServiceMonitor нужны компонентам следующих волн). Values в `gitops/platform/monitoring/kube-prometheus-stack.yaml`.
- Хранение: `retention: 3d` (как у Loki, ADR-04) и `retentionSize: 6GB` на PVC 8Gi (local-path).
  Глобальный `scrapeInterval: 30s`, Angie и Envoy опрашиваются раз в 15 с.
- `*SelectorNilUsesHelmValues: false`: Prometheus берёт ServiceMonitor, PodMonitor, Probe и PrometheusRule из
  всех namespace, а не только с меткой релиза. Мониторы лежат рядом с компонентом: Angie в
  `gitops/workloads/demo-app/servicemonitor.yaml`, Envoy в `gitops/platform/monitoring/manifests/envoy.yaml`
  (метрики Envoy по маршрутам, ADR-02), Argo CD, Calico и остальные в `manifests/` или в values своего чарта.
- Алерты в `manifests/rules.yaml`: `DemoAppDown`, `DemoAppHighErrorRate`, `GatewayProxyDown`,
  `GatewayUpstreamSlow`, `FluentdOutputErrors`, `FluentdBufferGrowing`. Канал уведомлений не настроен,
  алерты видны в UI Prometheus и Alertmanager.
- Дашборды как код: JSON в `manifests/dashboards/`, ConfigMap с меткой `grafana_dashboard: "1"`, их подхватывает
  sidecar Grafana. Домашний дашборд «MTS Hack: gateway, app, logs» задан `default_home_dashboard_path`.
- **SLO как код.** Спецификация `gitops/platform/monitoring/slo/demo-app.yaml`: availability и latency
  (250 мс), цель 99% за 30 дней. `make slo` запускает `sloth generate` и пишет
  `manifests/slo-rules.yaml`, этот PrometheusRule применяет Argo CD.
- Обе SLI считаются на Envoy по маршрутам `httproute/demo/*`. Счётчики Angie включают пробы kubelet
  (около 1 rps ответов 200) и размывают реальные 5xx. По той же причине `demo:http_5xx_ratio:rate5m` в
  `rules.yaml` тоже считается на Envoy.
- Без трафика в окне отношение равно `0/0 = NaN`, а Sloth строит 30-дневную SLI через `sum_over_time` по
  5-минутным отношениям: один NaN портит всё окно. Знаменатель задан как `(sum(rate(...)) > 0) or vector(1)`,
  поэтому без запросов ошибка равна 0. Серия 5xx у Envoy появляется только после первой ошибки, поэтому
  числитель доступности дополнен `or vector(0)`.
- Лимиты памяти с запасом под ноду 16 ГБ: Prometheus 4Gi (request 1Gi), Grafana 1536Mi. Grafana на лимите
  384Mi постоянно упиралась в него при нескольких открытых дашбордах, и запросы не укладывались в 15 с
  таймаута маршрута.

### Последствия

- Плюс: новый компонент подключается своим ServiceMonitor в своём каталоге, values Prometheus не трогаются.
- Плюс: SLO, алерты и дашборды лежат в git и проверяются в CI, ручных шагов в UI нет.
- Плюс: SLI на Gateway видит то же, что клиент: ответы маршрутов приложения без проб.
- Минус: окно SLO 30 дней, а Prometheus хранит 3 дня. 30-дневные SLI и остаток бюджета на стенде считаются
  не больше чем за 3 дня.
- Минус: в периоды без трафика ошибка SLI равна 0, это немного размывает среднюю ошибку за окно.
- Минус: стек тяжелее голого Prometheus: оператор, Alertmanager, Grafana, около 30 стандартных дашбордов.
- Нейтрально: `/error` отвечает 500 намеренно, каждый `make verify` немного тратит бюджет доступности.

### Как проверяется

- `make verify`, секция «Prometheus»: «target angie-v1 up», «target angie-v2 up», «Envoy targets up»,
  «PromQL angie_http_server_zones_responses{zone="demo"}», «PromQL: Envoy, node-exporter, kube-state-metrics,
  apiserver metrics (4/4)», «SLO recording rules (Sloth): availability and latency SLIs (2/2)».
- CI: workflow `ci`, job «lint and validate», шаг «SLO rules match the Sloth spec»: `make slo` и
  `git diff --exit-code` по `slo-rules.yaml`. Сгенерированный файл не может разойтись со спецификацией.
- CI: шаг «Render and validate Kubernetes manifests» проверяет PrometheusRule, ServiceMonitor и ConfigMap
  дашбордов kubeconform. Job e2e запускает `make verify` на чистом кластере.

## Плюсы и минусы вариантов

### Голый Prometheus

- Плюс: один под, меньше памяти.
- Минус: scrape-конфиг правится в одном месте вручную, ServiceMonitor из чартов не работают.
- Минус: Grafana, Alertmanager, node-exporter и kube-state-metrics ставятся и связываются отдельно.

### VictoriaMetrics

- Плюс: экономнее по памяти и диску, понимает ServiceMonitor через свой оператор.
- Минус: ТЗ требует Prometheus. vmagent и VMSingle совместимы по API, но это не Prometheus.

### Pyrra

- Плюс: UI с бюджетом ошибок.
- Минус: ещё один контроллер и под на одной ноде. Sloth даёт те же правила без рантайма.

### Правила вручную

- Плюс: нет генератора.
- Минус: multi-window multi-burn-rate алерты для двух SLO это десятки выражений, ошибку в окнах легко пропустить.

## Когда пересмотреть

- Нужна история дольше 3 дней или честное 30-дневное окно SLO: remote write во внешнее хранилище или больше
  retention и диска.
- Нужны уведомления: настроить receiver в Alertmanager.
- Растёт число серий или нод: VictoriaMetrics или шардирование.

## Ссылки

- Код: `gitops/platform/monitoring/kube-prometheus-stack.yaml`, `gitops/platform/monitoring/manifests/`,
  `gitops/platform/monitoring/slo/demo-app.yaml`, `gitops/workloads/demo-app/servicemonitor.yaml`
- Связанные ADR: ADR-02, ADR-03, ADR-04
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack>,
  <https://sloth.dev/>, <https://sre.google/workbook/alerting-on-slos/>
