# TODO

Что осталось сделать. Сделанное уходит из списка в коммит, его описание в README и ADR.

## До сдачи (2026-10-04 23:59 МСК)

- [x] Чистый прогон на новой ВМ (2026-10-03): `make infra-down infra-up deploy verify cis`, verify и kube-bench
      без FAIL. Флаги CIS в конфиге kubeadm применяются только при `kubeadm init`, поэтому прогон был с нуля.
- [ ] Проверка из браузера, как это сделает проверяющий (около 10 минут, с машины в сети стенда):
  - [ ] `hosts`: `<IP узла> app.mts-hack.local grafana.mts-hack.local prometheus.mts-hack.local argocd.mts-hack.local`;
  - [ ] `make credentials`, `make ca-cert`, импорт CA (или принять предупреждение браузера);
  - [ ] `http://app.mts-hack.local:30080` отвечает Hello World, `https://app.mts-hack.local:30443` без ошибки сертификата;
  - [ ] Grafana: вход, дашборды «MTS Hack: gateway, app, logs», «SLO / Detail», ArgoCD, Envoy с данными
        (сначала открыть `/missing` и `/error`, чтобы появились 4xx/5xx), Explore → Loki `{namespace="demo"}`;
  - [ ] Prometheus `/targets`: все `up`; `/alerts`: что горит, кроме `Watchdog`, и почему;
  - [ ] Argo CD: 13 приложений Synced/Healthy;
  - [ ] `http://grafana.mts-hack.local:30080` редиректит на HTTPS (301);
  - [ ] всё, что было неочевидно, дописать в README.
- [ ] Перечитать README и паспорт целиком, `make passport` (не больше 4 страниц).
- [ ] Формат `Ссылка.txt`: URL репозитория или `/tree/main`.
- [ ] Запустить `ci` вручную на финальном коммите `main` (Actions → ci → Run workflow): коммиты только с документацией
      фильтр `paths` пропускает, и у сдаваемого коммита не будет своего e2e.
- [ ] `make submission SURNAME=<фамилия при регистрации>`, загрузить архив заранее.
- [ ] Следить за чатом: организаторы обещали ответить про недоступные из РФ реестры (Docker Hub, `get.helm.sh`, `ghcr.io`).
- [ ] После 23:59 МСК 4 октября в `main` ничего не пушить.

## Настройки GitHub (руками, после дедлайна)

Сейчас всё пушится прямо в `main`, поэтому защита ветки включается после сдачи.

- [ ] Branch protection для `main`: изменения только через PR, обязательные проверки `ci` и `security`,
      запрет force-push и удаления. Поднимет Scorecard (Branch-Protection, Code-Review, CI-Tests).
- [ ] Заявка на OpenSSF Best Practices badge на bestpractices.dev (Scorecard: CII-Best-Practices).
- [ ] Подписанный релиз: тег на сданном коммите и GitHub Release с SBOM и подписью cosign (Scorecard: Signed-Releases).

## Сеть с ограничениями (если организаторы подтвердят проблему)

Зеркала реестров и адрес Helm уже задаются через [ansible/mirrors.example.yml](ansible/mirrors.example.yml).

- [ ] `HTTPS_PROXY` одной переменной для containerd, apt, Helm и repo-server Argo CD.
- [ ] Чарты с `*.github.io` и `charts.jetstack.io`: завендорить или брать из git-репозиториев проектов по тегу.
