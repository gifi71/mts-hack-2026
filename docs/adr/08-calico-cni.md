---
status: принято
date: 2026-10-04
deciders: Павел Дудко
related: [ADR-01, ADR-02, ADR-03, ADR-06]
---

# 08. Calico как CNI

> **Коротко.** В контексте одноузлового kubeadm-кластера на чужой ВМ эксперта, столкнувшись с тем, что
> подам нужна сеть до Argo CD, а namespace приложения закрыт NetworkPolicy, выбрали Calico 3.32 через
> tigera-operator с VXLAN без BGP и не стали брать Cilium и Flannel, чтобы NetworkPolicy реально
> применялись и сеть работала в любой сети, включая облачную, приняв отдельный оператор и около 340 МБ RAM
> на компоненты Calico.

## Контекст и проблема

kubeadm не ставит сеть подов: без CNI нода остаётся NotReady, а поды, включая Argo CD, не стартуют.
Какой CNI взять, чтобы он ставился автоматически, работал в неизвестной сети эксперта и применял
NetworkPolicy? Решение затрагивает роль `ansible/roles/calico`, подсеть подов `k8s_pod_subnet`,
NetworkPolicy в `gitops/workloads/demo-app/networkpolicy.yaml` и мониторинг Felix.

## Требования и ограничения

- Кластер на kubeadm, при прочих равных ему приоритет (docs/task/case.md, «Kubernetes-окружение»).
- Решение не зависит от сервисов облачного провайдера (docs/task/case.md, «Kubernetes-окружение»).
- Автоматизация от чистой ВМ до кластера (docs/task/qa.md).
- Базовые практики безопасности оцениваются (docs/task/case.md, критерий 4): namespace приложения работает
  под default deny (AGENTS.md, «Kubernetes и GitOps»), значит CNI обязан применять NetworkPolicy.
- Сеть эксперта неизвестна: облако, где L2 и BGP с соседями недоступны, или домашний гипервизор.
- CNI ставится до Argo CD, им управляет Ansible, а не GitOps (ADR-03).

## Рассмотренные варианты

1. Calico через tigera-operator, VXLAN без BGP
2. Cilium
3. Flannel

## Решение

Выбран вариант «Calico, VXLAN без BGP», потому что он применяет NetworkPolicy, ставится двумя Helm-чартами
без смены kube-proxy и работает поверх любой IP-сети.

- Calico v3.32.2 (`calico_version` в `ansible/roles/calico/defaults/main.yml`). Ansible ставит два чарта
  из GitHub Releases (причина в ADR-06): сначала `crd.projectcalico.org.v1` с CRD, затем
  `tigera-operator`. С v3.31 CRD вынесены в отдельный чарт и должны появиться раньше оператора.
- `calicoNetwork`: `bgp: Disabled`, один IP pool `default-ipv4-ippool` с CIDR из `k8s_pod_subnet`
  (по умолчанию `10.244.0.0/16`, `ansible/group_vars/all/main.yml`), `encapsulation: VXLAN`,
  `natOutgoing: Enabled`, `blockSize: 26`.
- Необязательные компоненты выключены ради памяти на одной ноде: `apiServer`, `goldmane`, `whisker`.
- Felix отдаёт метрики (`prometheusMetricsEnabled: true`). calico-node не объявляет порт 9091 в спеке
  пода, поэтому headless Service `calico-felix-metrics` и ServiceMonitor `calico-felix` в
  `gitops/platform/monitoring/manifests/calico.yaml` указывают на этот порт сети хоста.
- После установки Ansible ждёт Ready ноды и rollout CoreDNS: дальше Argo CD уже может стартовать.
- kube-proxy остаётся (iptables), eBPF-датаплейн Calico не включён.

### Последствия

- Плюс: NetworkPolicy применяются. В namespace `demo` default deny, вход только от прокси Envoy и от
  Prometheus на порт метрик, исходящего трафика нет.
- Плюс: VXLAN не требует BGP и L2-соседства, поэтому сеть подов работает и на облачной ВМ.
- Плюс: метрики Felix в Prometheus наравне с остальными компонентами платформы.
- Минус: отдельный оператор и его CRD. Около 340 МБ RAM на tigera-operator, calico-node,
  calico-kube-controllers и typha (замер на стенде 2026-10-04).
- Минус: Calico ставит Ansible, Argo CD им не управляет. Обновление идёт повторным `make deploy`.
- Нейтрально: подсеть подов задаётся до `kubeadm init`. Если она пересекается с сетью узла, preflight
  останавливает установку и предлагает `-e k8s_pod_subnet=...`.

### Как проверяется

- Ansible: «Wait for node to become Ready» и «Wait for CoreDNS» в роли `calico` не пропускают дальше без
  рабочей сети подов.
- `make verify`: все проверки Gateway API (маршрут до Angie через Envoy проходит при default deny в `demo`)
  и проверки Prometheus (скрейп Angie разрешён отдельной NetworkPolicy).
- CI: workflow `ci`, job «e2e on a clean Ubuntu 24.04 (kubeadm)»: установка Calico на чистом раннере и
  `make verify`.
- Prometheus: target `calico-felix` на `/targets`. Отдельной строки в `make verify` для него нет.
- Что NetworkPolicy именно блокирует запрещённый трафик, автоматически не проверяется: `make verify`
  проверяет только разрешённые пути.

## Плюсы и минусы вариантов

### Calico, VXLAN без BGP

- Плюс: NetworkPolicy, VXLAN поверх любой IP-сети, установка двумя чартами.
- Минус: оператор и CRD, больше компонентов, чем у Flannel.

### Cilium

- Плюс: eBPF, сетевая видимость (Hubble) и своя реализация Gateway API.
- Минус: замена kube-proxy и требования к ядру усложняют установку на kubeadm и в CI. Gateway API от
  Cilium привязал бы выбор шлюза к выбору CNI (ADR-02).

### Flannel

- Плюс: самый простой и лёгкий.
- Минус: не применяет NetworkPolicy, а default deny в `demo` обязателен по правилам репозитория.

## Когда пересмотреть

- Нужна проверка запрещённых путей NetworkPolicy в `make verify` или CI.
- Мультинода (ADR-01): проверить VXLAN между нодами (MTU, UDP 4789 в firewall).
- Нужна сетевая видимость или eBPF-датаплейн: тогда сравнить с Cilium заново.

## Ссылки

- Код: `ansible/roles/calico/`, `ansible/group_vars/all/main.yml`,
  `gitops/workloads/demo-app/networkpolicy.yaml`, `gitops/platform/monitoring/manifests/calico.yaml`
- Связанные ADR: ADR-01, ADR-02, ADR-03, ADR-06
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://docs.tigera.io/calico/3.32/getting-started/kubernetes/requirements>,
  <https://docs.tigera.io/calico/3.32/networking/configuring/vxlan-ipip>
