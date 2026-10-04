# Архитектурные решения (ADR)

Одно решение на файл: контекст, решение, рассмотренные варианты, последствия.

| № | Решение |
|---|---|
| [0001](0001-single-node-kubeadm.md) | Одна нода на kubeadm |
| [0002](0002-envoy-gateway-nodeport.md) | Envoy Gateway и NodePort вместо LoadBalancer с MetalLB |
| [0003](0003-gitops-argocd-app-of-apps.md) | Ansible до CNI и Argo CD, дальше GitOps (app of apps) |
| [0004](0004-fluentd-loki.md) | Fluentd → Loki, свой образ Fluentd |
| [0005](0005-opentofu-optional-layer.md) | OpenTofu как опциональный слой, Proxmox |
| [0006](0006-registry-and-network-resilience.md) | Установка при недоступных реестрах и чужом DNS |
| [0007](0007-kyverno-and-compliance-checks.md) | Kyverno для подписи образов, CIS и Kubescape для соответствия |

Шаблон для новых решений: [xxxx-template.md](xxxx-template.md).
