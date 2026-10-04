# Архитектурные решения (ADR)

Одно решение на файл: контекст, решение, рассмотренные варианты, последствия.

| № | Решение |
|---|---|
| [01](01-single-node-kubeadm.md) | Одна нода на kubeadm |
| [02](02-envoy-gateway-nodeport.md) | Envoy Gateway и NodePort вместо LoadBalancer с MetalLB |
| [03](03-gitops-argocd-app-of-apps.md) | Ansible до CNI и Argo CD, дальше GitOps (app of apps) |
| [04](04-fluentd-loki.md) | Fluentd → Loki, свой образ Fluentd |
| [05](05-opentofu-optional-layer.md) | OpenTofu как опциональный слой, Proxmox |
| [06](06-registry-and-network-resilience.md) | Установка при недоступных реестрах и чужом DNS |
| [07](07-kyverno-and-compliance-checks.md) | Kyverno для подписи образов, CIS и Kubescape для соответствия |

Шаблон для новых решений: [00-template.md](00-template.md).
