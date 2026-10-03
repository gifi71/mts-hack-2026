# 0006. Установка при недоступных реестрах и чужом DNS

## Контекст

Эксперты, скорее всего, в РФ. Docker Hub ограничивает анонимные загрузки и бывает недоступен.
На стенде автора при разработке нашлись ещё две проблемы окружения.

## Решение

- **Docker Hub через зеркало**: containerd настроен с `hosts.toml` для `docker.io`, сначала `mirror.gcr.io`,
  потом сам Docker Hub. Так тянутся Envoy, Envoy Gateway, Grafana, Loki, redis, local-path-provisioner и busybox.
  Образы в чартах переопределены только там, где дефолт был вне этих реестров или плавающий:
  redis (Argo CD, по умолчанию ECR Public), busybox (local-path-provisioner, по умолчанию `latest`),
  sidecar Loki (с Docker Hub на quay.io).
- **Чарт Envoy Gateway завендорен**: он публикуется только как OCI-артефакт на Docker Hub.
- **Calico из GitHub Releases**: Helm-репозиторий `docs.tigera.io` со стенда отдавал ~0.4 КБ/с.
- **resolv.conf для kubelet без search-доменов**: Proxmox передал ВМ свой search-домен с wildcard-записью.
  При `ndots:5` под резолвил `github.com` как `github.com.<домен>`, и Argo CD не мог скачать репозиторий.
  Теперь поды получают только кластерные search-домены и upstream-серверы.
- Остальные образы берутся с `registry.k8s.io`, `quay.io`, `ghcr.io`, `docker.angie.software`.

## Последствия

- Если Docker Hub недоступен, образы `docker.io` приходят из `mirror.gcr.io`. Если недоступно и зеркало,
  установка не пройдёт: зеркал для `registry.k8s.io` и `ghcr.io` нет.
- По Q&A организаторов у проверяющих интернет есть ([docs/task/qa-2026-10-02.md](../task/qa-2026-10-02.md)).
  Из некоторых российских сетей без VPN недоступны Docker Hub, `get.helm.sh`, `registry.k8s.io`, `ghcr.io`.
  Следующий шаг: переменные для зеркал всех реестров и прокси для containerd, apt и Argo CD.
- При обновлении Envoy Gateway чарт нужно перевендорить (`helm pull ... --untar`).
