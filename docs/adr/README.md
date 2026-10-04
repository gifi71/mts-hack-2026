# Архитектурные решения (ADR)

Одно решение на файл по шаблону [00-template.md](00-template.md) (основа MADR 4.0): статус и дата,
краткая формулировка, контекст, требования, рассмотренные варианты, решение, последствия,
как решение проверяется, когда его пересмотреть.

| № | Решение |
|---|---|
| [01](01-single-node-kubeadm.md) | Одна нода на kubeadm |
| [02](02-envoy-gateway-nodeport.md) | Envoy Gateway и NodePort вместо LoadBalancer с MetalLB |
| [03](03-gitops-argocd-app-of-apps.md) | Ansible до CNI и Argo CD, дальше GitOps (app of apps) |
| [04](04-fluentd-loki.md) | Fluentd → Loki, свой образ Fluentd |
| [05](05-opentofu-optional-layer.md) | OpenTofu как опциональный слой, Proxmox |
| [06](06-registry-and-network-resilience.md) | Установка при недоступных реестрах и чужом DNS |
| [07](07-kyverno-and-compliance-checks.md) | Kyverno для подписи образов, CIS и Kubescape для соответствия |
| [08](08-calico-cni.md) | Calico как CNI |
| [09](09-monitoring-prometheus-slo.md) | kube-prometheus-stack и SLO как код (Sloth) |
| [10](10-angie-demo-app.md) | Angie как демо-приложение |
| [11](11-tls-and-secrets.md) | Самоподписанный CA через cert-manager, секреты генерируются при установке |

Новое решение: скопировать шаблон в `NN-<короткое-имя>.md` и добавить строку в таблицу.
