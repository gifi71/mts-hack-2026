---
status: принято
date: 2026-10-03
deciders: Павел Дудко
related: [ADR-03, ADR-05]
---

# 01. Одна нода на kubeadm

> **Коротко.** В контексте проверки решения экспертами на их собственной ВМ, столкнувшись с требованием
> воспроизводимости при минимуме ручных действий и одним раннером в CI, выбрали кластер kubeadm из одной
> ноды Ubuntu 24.04 и не стали брать мультиноду и kind/k3s/minikube, чтобы эксперт поднимал ровно тот
> сценарий, который проходит e2e в CI, приняв отсутствие HA.

## Контекст и проблема

Сколько нод в кластере и чем его ставить? От этого зависит, сколько ВМ готовит эксперт, что может
проверить CI и что описывает README. Решение затрагивает inventory (`ansible/inventory/`), роли
`kubernetes` и `kubeadm`, job e2e в `.github/workflows/ci.yml`.

## Требования и ограничения

- При прочих равных приоритет у kubeadm (docs/task/case.md, «Kubernetes-окружение», критерий 1, 30 баллов).
- Отдельно оцениваются воспроизводимость и число ручных действий (docs/task/case.md, критерий 2, 25 баллов).
- Single node баллы не снижает, ресурсы участника ограничены. Машина проверки: 4 vCPU, 16 ГБ RAM
  (docs/task/qa.md).
- Идемпотентность эксперты проверяют повторным развёртыванием с чистой ВМ (docs/task/qa.md).
- В CI один раннер `ubuntu-24.04`: проверить можно только то, что помещается на одну машину.

## Рассмотренные варианты

1. kubeadm, одна нода, control plane без taint
2. kubeadm, 1 control plane + 2 worker
3. kind, k3s или minikube

## Решение

Выбран вариант «kubeadm, одна нода», потому что только он сочетает приоритетный kubeadm с тем же
сценарием, который целиком проверяет CI.

- Kubernetes 1.36.5 (`k8s_version` в `ansible/group_vars/all/main.yml`) на Ubuntu 24.04.
- Taint с control plane снимается, когда группа `workers` пуста (`kubeadm_untaint_control_plane` в
  `ansible/roles/kubeadm/defaults/main.yml`). Рабочая нагрузка живёт на той же ноде.
- В inventory есть группы `control_plane` и `workers`. Подготовка ОС (`node_prep`, `containerd`,
  `kubernetes`) идёт на всю группу `k8s_cluster`. Присоединение worker (`kubeadm join`) не реализовано.

### Последствия

- Плюс: эксперт поднимает решение на одной ВМ одной командой `make deploy`. Этот же сценарий проходит e2e в CI.
- Плюс: требования к ВМ (4 vCPU, 8 ГБ RAM, 30 ГБ диска) ниже машины проверки. Лимиты памяти подов заданы
  с запасом под 16 ГБ, как у проверяющих.
- Минус: HA нет. Потеря ноды означает потерю кластера и данных Prometheus и Loki (local-path).
- Минус: control plane и приложение делят ресурсы одной ноды.
- Нейтрально: для второй ноды нужна роль с `kubeadm join` и проверка сети Calico между нодами.

### Как проверяется

- `make verify`: «node Ready» с версией kubelet, «Argo CD: N applications Synced/Healthy».
- CI: workflow `ci`, job «e2e on a clean Ubuntu 24.04 (kubeadm)»: `make deploy` на чистом раннере,
  повторный `make deploy` с проверкой `changed=0 failed=0`, затем `make verify`.

## Плюсы и минусы вариантов

### kubeadm, 1 control plane + 2 worker

- Плюс: ближе к продакшену, видно распределение подов по нодам.
- Минус: эксперту нужны три ВМ, SSH между ними и правка inventory.
- Минус: больше точек отказа в чужой сети: MTU, firewall, VXLAN между нодами.
- Минус: CI на одном раннере такой кластер не проверит.

### kind, k3s или minikube

- Плюс: быстрее ставятся, меньше шагов в Ansible.
- Минус: ТЗ отдаёт приоритет kubeadm.

## Когда пересмотреть

- Нужен HA control plane или проверка отказа ноды.
- В CI появляется несколько машин (self-hosted раннеры или ВМ в облаке) для мультинодового e2e.

## Ссылки

- Код: `ansible/site.yml`, `ansible/roles/kubeadm/`, `ansible/inventory/hosts.example.yml`
- Связанные ADR: ADR-03, ADR-05
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/>
