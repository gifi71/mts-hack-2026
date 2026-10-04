# 02. Envoy Gateway и NodePort вместо LoadBalancer с MetalLB

## Контекст

Нужна open-source реализация Gateway API. ingress-nginx закрыт в марте 2026, отрасль переходит на Gateway API.
Сервис Gateway должен быть доступен снаружи на любой ВМ эксперта, включая облачные.

## Решение

- **Envoy Gateway 1.9**: проект Envoy в CNCF, проходит conformance-тесты Gateway API, метрики Envoy по маршрутам,
  TLS, splitting.
- Сервис data plane (Envoy proxy) публикуется через NodePort с фиксированными портами 30080/30443.
  Это задаёт ресурс `EnvoyProxy` (`envoyService.type: NodePort` и патч портов), на него ссылается `GatewayClass`.
- Маршрутизация описана только стандартными ресурсами Gateway API (`GatewayClass`, `Gateway`, `HTTPRoute`).
  Единственное расширение Envoy Gateway: `EnvoyProxy` для параметров сервиса, стандартного ресурса для этого нет.

## Варианты

- **Cilium Gateway API**: заменил бы и CNI, но сложнее на kubeadm и в CI.
- **NGINX Gateway Fabric**: проще, но меньше функций и метрик.
- **LoadBalancer + MetalLB L2**: L2-анонсы не работают в облачных сетях (ARP для чужих IP не пропускается),
  а эксперту пришлось бы выбирать свободный диапазон адресов в своей сети.

## Последствия

- `curl http://<IP ноды>:30080/` работает в любой сети без настройки.
- Порты нестандартные (30080/30443). В проде перед нодой ставится внешний балансировщик или LoadBalancer.
- Фиксированные nodePort работают при одном Gateway на класс. Для нескольких Gateway нужны разные порты.
