---
status: принято
date: 2026-10-03
deciders: Павел Дудко
related: [ADR-01, ADR-03, ADR-06, ADR-08, ADR-09, ADR-10, ADR-11]
---

# 02. Envoy Gateway и NodePort вместо LoadBalancer с MetalLB

> **Коротко.** В контексте публикации приложения через Gateway API на чужой ВМ эксперта, столкнувшись с
> тем, что сервис Gateway должен быть доступен снаружи в любой сети, включая облачную, выбрали Envoy Gateway
> с сервисом data plane типа NodePort на фиксированных портах 30080/30443 и не стали брать LoadBalancer с
> MetalLB, Cilium Gateway API и NGINX Gateway Fabric, чтобы `curl http://<IP ноды>:30080/` работал без
> настройки сети, приняв нестандартные порты.

## Контекст и проблема

Какую реализацию Gateway API взять и как вывести её data plane наружу? ingress-nginx закрыт в марте 2026,
отрасль переходит на Gateway API. Эксперт ставит решение на свою ВМ, его сеть заранее неизвестна.
Решение затрагивает Application `envoy-gateway` и `gateway-api-crds` (`gitops/apps/templates/`),
ресурсы в `gitops/platform/gateway/` и маршрут приложения `gitops/workloads/demo-app/httproute.yaml`.

## Требования и ограничения

- Доступ к приложению через Gateway API: реализация, GatewayClass, Gateway, HTTPRoute на Service
  приложения; в README название и версия реализации и способ проверки через curl
  ([docs/task/case.md](../task/case.md), «Gateway API»).
- Дополнительные баллы за несколько маршрутов, маршрутизацию по hostname и path, несколько backend, TLS
  и traffic splitting ([docs/task/case.md](../task/case.md), «Возможности для улучшения решения»).
- Эксперты прописывают имя из Gateway API в `hosts` и открывают приложение с клиента, в том числе
  из браузера ([docs/task/qa.md](../task/qa.md)).
- Решение не зависит от коммерческих сервисов облачного провайдера, значит, облачного LoadBalancer нет
  ([docs/task/case.md](../task/case.md), «Kubernetes-окружение»).
- AGENTS.md: в Gateway API только стандартные ресурсы, расширения реализации только там, где стандартного нет.

## Рассмотренные варианты

1. Envoy Gateway, сервис data plane типа NodePort с фиксированными портами
2. Envoy Gateway, LoadBalancer + MetalLB L2
3. Cilium Gateway API
4. NGINX Gateway Fabric

## Решение

Выбран вариант «Envoy Gateway и NodePort», потому что только он даёт доступ к Gateway в любой сети
эксперта без подбора адресов и без смены CNI.

- Envoy Gateway 1.9.2 (Envoy 1.39.1), Gateway API 1.6.1 standard channel. Чарты `gateway-helm` и
  `gateway-crds-helm` v1.9.2 завендорены в `gitops/platform/envoy-gateway/charts/` (причина в ADR-06).
- `EnvoyProxy nodeport` (`gitops/platform/gateway/envoyproxy.yaml`): `envoyService.type: NodePort`,
  `externalTrafficPolicy: Cluster`, патч портов 80 → 30080 и 443 → 30443. На него ссылается
  `GatewayClass envoy` через `parametersRef`.
- `Gateway edge` (`gitops/platform/gateway/gateway.yaml`) с двумя listener: `http` на 80 без hostname и
  `https` на 443 для `*.mts-hack.local` с TLS от cert-manager (Secret `mts-hack-tls`). Маршруты
  принимаются только из namespace `demo`, `monitoring`, `argocd`, `envoy-gateway-system`.
- Маршрутизация описана только стандартными `HTTPRoute`: приложение по hostname, header и path с rewrite,
  splitting 90/10 между v1 и v2; Grafana, Prometheus и Argo CD по HTTPS с редиректом с HTTP.
  Единственное расширение Envoy Gateway: `EnvoyProxy` для параметров сервиса, стандартного ресурса для этого нет.
- Метрики Envoy по маршрутам и контроллера собирает Prometheus: `PodMonitor envoy-proxy` и
  `ServiceMonitor envoy-gateway` в `gitops/platform/monitoring/manifests/envoy.yaml`.

### Последствия

- Плюс: `curl http://<IP ноды>:30080/` работает в любой сети без настройки.
- Плюс: маршрутизация переносима на другую реализацию Gateway API, кроме ресурса `EnvoyProxy`.
- Минус: порты нестандартные (30080/30443). В продакшене перед нодой ставится внешний балансировщик или
  LoadBalancer.
- Минус: `EnvoyProxy` задан на уровне GatewayClass, поэтому фиксированные nodePort работают при одном
  Gateway на класс. Для нескольких Gateway нужны разные порты.
- Нейтрально: при обновлении Envoy Gateway чарты нужно перевендорить (`helm pull ... --untar`, команды в
  `gitops/platform/envoy-gateway/charts/README.md`).

### Как проверяется

- `make verify`, раздел «Gateway API»: «Gateway edge Programmed», «curl http://<IP>:30080/ -> 'Hello World!'»,
  «HTTPS with the cert-manager CA», «header X-Canary: always -> v2», «path /v2/ (rewritten to /) -> v2»,
  «traffic split 90/10», ответы 404 и 500.
- `make verify`, раздел «Prometheus»: «Envoy targets up».
- CI: workflow `ci`, job «lint and validate», шаг «Render and validate Kubernetes manifests» (kubeconform);
  job «e2e on a clean Ubuntu 24.04 (kubeadm)», шаг `make verify`.

## Плюсы и минусы вариантов

### Envoy Gateway, NodePort

- Плюс: проект Envoy в CNCF, проходит conformance-тесты Gateway API.
- Плюс: метрики Envoy по маршрутам, TLS и splitting из коробки.
- Минус: нестандартные порты 30080/30443.

### Envoy Gateway, LoadBalancer + MetalLB L2

- Плюс: стандартные порты 80/443, выглядит как в продакшене.
- Минус: L2-анонсы не работают в облачных сетях, ARP для чужих IP не пропускается.
- Минус: эксперту пришлось бы выбирать свободный диапазон адресов в своей сети.

### Cilium Gateway API

- Плюс: заменил бы и CNI, одна система для сети и Gateway.
- Минус: сложнее на kubeadm и в CI.

### NGINX Gateway Fabric

- Плюс: проще.
- Минус: меньше функций и метрик.

## Когда пересмотреть

- Перед нодой есть внешний балансировщик или облачный LoadBalancer.
- Нужно несколько Gateway одного класса.
- Мультинода (ADR-01): нужен один стабильный адрес входа, а не IP конкретной ноды.

## Ссылки

- Код: `gitops/platform/gateway/`, `gitops/workloads/demo-app/httproute.yaml`,
  `gitops/apps/templates/envoy-gateway.yaml`, `gitops/apps/templates/gateway-api-crds.yaml`
- Связанные ADR: ADR-01, ADR-03, ADR-06, ADR-08, ADR-09, ADR-10, ADR-11
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://gateway.envoyproxy.io/news/releases/matrix/>,
  <https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/>
