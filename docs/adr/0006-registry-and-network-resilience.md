# 0006. Установка при недоступных реестрах и чужом DNS

## Контекст

Эксперты, скорее всего, в РФ. Docker Hub ограничивает анонимные загрузки и бывает недоступен.
На стенде автора при разработке нашлись ещё две проблемы окружения.

## Решение

- **Docker Hub через зеркало**: containerd настроен с `hosts.toml` для `docker.io`, сначала `mirror.gcr.io`,
  потом сам Docker Hub. Чарты не переопределяют образы.
- **Чарт Envoy Gateway завендорен**: он публикуется только как OCI-артефакт на Docker Hub.
- **Calico из GitHub Releases**: Helm-репозиторий `docs.tigera.io` со стенда отдавал ~0.4 КБ/с.
- **resolv.conf для kubelet без search-доменов**: Proxmox передал ВМ свой search-домен с wildcard-записью.
  При `ndots:5` под резолвил `github.com` как `github.com.<домен>`, и Argo CD не мог скачать репозиторий.
  Теперь поды получают только кластерные search-домены и upstream-серверы.
- Остальные образы берутся с `registry.k8s.io`, `quay.io`, `ghcr.io`, `docker.angie.software`.

## Последствия

- Установка не зависит от доступности Docker Hub.
- При обновлении Envoy Gateway чарт нужно перевендорить (`helm pull ... --untar`).
