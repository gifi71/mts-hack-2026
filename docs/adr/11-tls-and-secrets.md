---
status: принято
date: 2026-10-04
deciders: Павел Дудко
related: [ADR-02, ADR-03]
---

# 11. Самоподписанный CA через cert-manager, секреты генерируются при установке

> **Коротко.** В контексте стенда эксперта без публичного DNS, столкнувшись с требованием не хранить
> секреты в репозитории и с желанием показать TLS в Gateway API, выбрали свой CA в cert-manager для
> `*.mts-hack.local` и генерацию паролей на узле при установке, и не стали брать Let's Encrypt,
> сертификат в git, SOPS, Sealed Secrets и Vault, чтобы HTTPS и пароли появлялись без ручных шагов и
> без секретов в git, приняв, что клиенту нужно импортировать CA.

## Контекст и проблема

Где взять сертификат для HTTPS на Gateway и откуда брать пароли Grafana и Argo CD, если у эксперта нет
публичного домена, а секреты нельзя класть в репозиторий? Решение затрагивает `gitops/platform/gateway/pki.yaml`,
listener `https` в `gitops/platform/gateway/gateway.yaml`, роль `ansible/roles/platform_secrets` и
`ansible/info.yml` (`make credentials`, `make ca-cert`).

## Требования и ограничения

- В репозитории нет реальных паролей, токенов, приватных ключей. Нужные секреты передаются через переменные
  окружения, Secret или шаблон конфигурации ([docs/task/case.md](../task/case.md), «Требования к безопасности»).
- Оценивается отсутствие чувствительных данных в репозитории ([docs/task/case.md](../task/case.md), критерий 4).
- TLS входит в список дополнительных возможностей Gateway API ([docs/task/case.md](../task/case.md),
  «Возможности для улучшения решения»).
- Самоподписанного сертификата достаточно. Эксперты прописывают имена из Gateway API в `hosts` и открывают
  приложение в браузере ([docs/task/qa.md](../task/qa.md)).
- Никаких ручных шагов в UI и повторный запуск ничего не ломает (AGENTS.md, правила 3 и 4).

## Рассмотренные варианты

TLS:

1. Свой CA в cert-manager: self-signed корень, CA-issuer, wildcard-сертификат
2. Let's Encrypt через cert-manager (ACME)
3. Готовый сертификат и ключ в репозитории
4. Без TLS, только HTTP

Секреты:

1. Генерация на узле при установке, Secret создаётся до синхронизации Argo CD
2. SOPS с age
3. Sealed Secrets
4. External Secrets с Vault

## Решение

Выбраны «свой CA в cert-manager» и «генерация при установке», потому что только они работают на любой ВМ
эксперта без внешних сервисов и не кладут в git ни ключей, ни паролей.

- Цепочка в `gitops/platform/gateway/pki.yaml`: ClusterIssuer `selfsigned` выпускает CA `mts-hack-ca`
  (Certificate в namespace `cert-manager`, `isCA: true`, ECDSA P-256, срок 10 лет). ClusterIssuer `mts-hack-ca`
  подписывает wildcard `*.mts-hack.local` в Secret `mts-hack-tls` (namespace `envoy-gateway-system`, срок
  90 дней, `renewBefore: 360h`, ключ меняется при каждом продлении: `rotationPolicy: Always`).
- Listener `https` Gateway `edge` на 443 для `*.mts-hack.local` терминирует TLS с `mts-hack-tls` (ADR-02).
  HTTPRoute `https-redirect` отвечает 301 на `https://...:30443` для UI.
- `make ca-cert` (`ansible/info.yml`, тег `ca`) достаёт `ca.crt` из Secret `mts-hack-ca` и сохраняет
  `mts-hack-ca.crt` на машине эксперта. `*.crt`, `*.key`, `*.pem` в `.gitignore`.
- Пароль Grafana генерирует роль `platform_secrets` (24 символа, `ansible.builtin.password`) в Secret
  `grafana-admin` в namespace `monitoring`, только если Secret ещё нет: повторный `make deploy` пароль не меняет.
  Задача с паролем под `no_log`. kube-prometheus-stack читает его через `grafana.admin.existingSecret`.
  Роль идёт до Argo CD (ADR-03), поэтому Grafana стартует уже с этим Secret.
- Пароль Argo CD генерирует сам Argo CD при первом запуске в `argocd-initial-admin-secret`.
- `make credentials` (`ansible/info.yml`, тег `credentials`) печатает оба пароля, чтение Secret под `no_log`.
- Секреты в git ловит gitleaks: хук в `.pre-commit-config.yaml` и job `secrets in git history (gitleaks)` в
  workflow `security`.

### Последствия

- Плюс: HTTPS и пароли появляются без ручных шагов и без внешних сервисов, в git нет ни ключей, ни паролей.
- Плюс: продление сертификата автоматическое, ключ wildcard-сертификата меняется при каждом продлении.
- Минус: браузер доверяет сертификату только после импорта `mts-hack-ca.crt`, без него предупреждение.
- Минус: HTTPS только по именам `*.mts-hack.local`: `https://<IP>:30443` без имени не откроется (нет SNI).
- Минус: ключ CA лежит в Secret `cert-manager/mts-hack-ca` без шифрования etcd. Кто читает Secret в этом
  namespace, может выпустить сертификат на любое имя, которому доверяет клиент с импортированным CA.
- Минус: пароль Grafana при создании Secret передаётся в `kubectl --from-literal` и на время команды виден
  в списке процессов узла. `no_log` закрывает только вывод Ansible.
- Нейтрально: начальный пароль Argo CD остаётся в `argocd-initial-admin-secret`, пока его не сменят и не удалят.

### Как проверяется

- `make verify`: «HTTPS with the cert-manager CA -> 'Hello World!'»: `curl --cacert` с CA из Secret
  `mts-hack-ca` к `https://app.mts-hack.local:30443/`. Header-, path- и split-проверки тоже идут по HTTPS.
- CI: workflow `security`, job «secrets in git history (gitleaks)»; хук gitleaks в pre-commit (job «lint and validate» в `ci`).
- Вручную: `make ca-cert`, затем `curl --cacert mts-hack-ca.crt --resolve app.mts-hack.local:30443:<IP>
  https://app.mts-hack.local:30443/`; `make credentials` и вход в Grafana и Argo CD.

## Плюсы и минусы вариантов

### Let's Encrypt через cert-manager

- Плюс: браузер доверяет без импорта CA.
- Минус: нужен публичный домен и доступ из интернета к HTTP-01 или API DNS-провайдера для DNS-01.
  У эксперта имена есть только в `hosts`.

### Сертификат и ключ в репозитории

- Плюс: проще всего, cert-manager не нужен.
- Минус: приватный ключ в git, прямо запрещено ТЗ. Одинаковый ключ у всех, кто склонировал репозиторий.

### Без TLS

- Плюс: ничего не нужно настраивать.
- Минус: пароли UI идут открытым текстом, TLS в Gateway API не показан.

### SOPS с age

- Плюс: секреты версионируются в git в зашифрованном виде.
- Минус: эксперту нужен приватный ключ age, а передать его без доступа к инфраструктуре участника нельзя.

### Sealed Secrets

- Плюс: зашифрованный Secret в git, расшифровывает контроллер в кластере.
- Минус: ключ контроллера генерируется в каждом новом кластере, заранее запечатанные секреты у эксперта
  не расшифруются. Ещё один контроллер на одной ноде.

### External Secrets с Vault

- Плюс: стандарт для продакшена: ротация, аудит доступа.
- Минус: нужен Vault, которого у эксперта нет. Поднимать его в том же кластере ради двух паролей избыточно.

## Когда пересмотреть

- Появляется публичный домен: ACME-issuer в cert-manager вместо своего CA.
- Секретов становится больше двух или кластеров несколько: External Secrets или Sealed Secrets.
- Нужна защита ключа CA: шифрование Secret в etcd (`EncryptionConfiguration` в kubeadm) или внешний CA.

## Ссылки

- Код: `gitops/platform/gateway/pki.yaml`, `gitops/platform/gateway/gateway.yaml`,
  `gitops/platform/gateway/routes.yaml`, `ansible/roles/platform_secrets/`, `ansible/info.yml`
- Связанные ADR: ADR-02, ADR-03
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://cert-manager.io/docs/configuration/selfsigned/#bootstrapping-ca-issuers>,
  <https://cert-manager.io/docs/configuration/ca/>
