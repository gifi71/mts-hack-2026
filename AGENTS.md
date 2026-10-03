# AGENTS.md

Инструкции для ИИ-агентов (Claude Code, Codex, Cursor и др.), работающих в этом репозитории.
Людям сначала читать `README.md`.

## Проект

Решение кейса DevOps хакатона MTC ENGINEER HACK 2026: одноузловой Kubernetes на kubeadm,
демо-приложение Angie, доступ через Gateway API (Envoy Gateway), метрики в Prometheus, логи через
Fluentd в Loki.
Всё разворачивается автоматически на Ubuntu 24.04.

Проверяющие разворачивают решение у себя по README. Доступа к инфраструктуре автора у них нет.

Дедлайн: **2026-10-04 23:59 МСК**. После него в `main` ничего не коммитить и не пушить.

## Главные правила

1. Обязательная часть ТЗ важнее дополнительных фич. Не начинай фичу, пока базовый сценарий сломан.
2. Кластер одноузловой: одна ВМ Ubuntu 24.04 (kubeadm, control plane без taint). Мультиноду не делаем
   (решение 2026-10-03, организаторы подтвердили, что single node баллы не снижает, см. ADR 0001).
   Группы inventory `control_plane`/`workers` оставлены как задел.
3. Решение воспроизводится из репозитория на чистой Ubuntu 24.04. Никаких ручных шагов в UI,
   захардкоженных IP, путей и имён из домашней лаборатории автора.
4. Повторный запуск любого шага (`tofu apply`, плейбук, синхронизация Argo CD) ничего не ломает
   и при неизменной конфигурации ничего не меняет.
5. Каждая версия зафиксирована: провайдеры, Helm-чарты, образы, пакеты. Никаких `latest`.
6. Образы берём из `registry.k8s.io`, `quay.io`, `ghcr.io` или официального реестра проекта.
   Docker Hub из РФ работает нестабильно, используй его только если альтернативы нет.
7. Любое утверждение в README и паспорте должно подтверждаться кодом в репозитории.

## Структура

```
infra/tofu/          OpenTofu: одна ВМ Ubuntu 24.04 на Proxmox, inventory и known_hosts. Опционально.
  templates/         cloud-init
  modules/           ansible-inventory (+ tofu test)
  proxmox/           root-модуль
ansible/             site.yml (развёртывание), verify.yml, info.yml; роли: узел, kubeadm, Calico, Argo CD
gitops/
  apps/              Helm-чарт app-of-apps: Argo CD Application на компонент, порядок через sync-wave.
                     Root Application создаёт Ansible (roles/argocd/templates/root-app.yaml.j2)
  platform/<comp>/   values и манифесты компонента: argocd, envoy-gateway, gateway, cert-manager, monitoring,
                     logging, local-path-provisioner
  workloads/         демо-приложение (Kustomize base + overlays)
tests/smoke/         verify.sh: проверки Gateway, метрик и логов (make verify)
images/fluentd/      Dockerfile образа Fluentd с плагином Loki (собирается в CI)
scripts/             вспомогательные скрипты (ssh-node.sh)
docs/adr/            архитектурные решения, одно решение на файл
docs/passport/       исходники паспорта решения
docs/task/           текст кейса и ответы организаторов (Q&A): источник требований
.github/workflows/   CI
Makefile             единая точка входа, все команды через него
```

Новый компонент кластера: `gitops/apps/<comp>.yaml` плюс `gitops/platform/<comp>/`. Не создавай
параллельных папок с манифестами.

## Команды

```bash
make help                 # список целей
make deploy               # Ansible + Argo CD, идемпотентно (INVENTORY=... для своего inventory)
make verify               # smoke-тесты: Gateway API, Prometheus, Loki
make credentials          # пароли Grafana и Argo CD
make ca-cert              # локальный CA в mts-hack-ca.crt
make ssh                  # shell на ноде
make infra-up / infra-down   # ВМ на Proxmox (OpenTofu)
make tofu-check           # fmt, validate, tofu test
make manifests-check      # helm lint + kubeconform по всем отрендеренным манифестам
make passport             # docs/passport/Паспорт.pdf
make submission SURNAME=…  # dist/<SURNAME>.zip: Ссылка.txt + Паспорт.pdf для сдачи
make lock                 # пересобрать ansible/requirements.txt (uv, хеши) после правки requirements.in
```

Python-зависимости: правишь только `ansible/requirements.in`, потом `make lock`. `requirements.txt` руками не редактировать.

`ANSIBLE_ARGS` передаётся во все цели с плейбуками: `-K` (пароль sudo), `-e gitops_revision=<ветка>` и т.п.

Ansible-lint локально: `cd ansible && uvx --with ansible-core==2.21.4 ansible-lint --profile production site.yml verify.yml info.yml`.

Добавил цель в Makefile: добавь к ней `## описание` и обнови этот список.

## Как писать код

**Общее**
- Пиши как окружающий код: те же имена, отступы, плотность комментариев.
- Комментарий объясняет причину, а не пересказывает код.
- Никакого мёртвого кода, закомментированных блоков и TODO без пояснения.

**OpenTofu**
- Только OpenTofu (`tofu`), не Terraform. Провайдеры из `registry.opentofu.org`.
- У каждой переменной есть `description` и `type`, у критичных есть `validation`.
- `.terraform.lock.hcl` коммитим. State, `*.tfvars`, `.terraform/` не коммитим.
- После изменений: `make tofu-check`.

**Ansible**
- Роли идемпотентны: модули вместо `shell`/`command`. Если `command` неизбежен, ставь `creates`,
  `changed_when` или `when`.
- Полные имена модулей (`ansible.builtin.apt`, а не `apt`).
- Переменные роли с префиксом имени роли. Значения по умолчанию в `defaults/main.yml`.
- Код должен проходить `ansible-lint` в профиле `production`.

**Kubernetes и GitOps**
- Всё, что в кластере, описано в `gitops/`. `kubectl apply` руками допустим только для отладки.
- У каждого workload есть `resources.requests/limits`, probes, `securityContext`
  (`runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop `ALL`).
- Namespace приложений работает в Pod Security `restricted` и закрыт NetworkPolicy по умолчанию.
- Envoy Gateway публикуется через NodePort, без MetalLB: L2-анонсы не работают в облачных сетях.
- Gateway API: только стандартные ресурсы (`GatewayClass`, `Gateway`, `HTTPRoute`). Расширения
  Envoy Gateway используй, только если стандартного ресурса нет.

**Shell**
- `#!/usr/bin/env bash` и `set -euo pipefail`. Скрипт проходит `shellcheck`.

## Безопасность

- В репозиторий не попадают пароли, токены, приватные ключи, kubeconfig, персональные данные.
- Секреты передаются через переменные окружения или генерируются при установке.
  Для конфигов с секретами коммитим только `*.example`.
- Перед коммитом проверь diff глазами на секреты. В CI работает gitleaks.
- Не ослабляй проверки безопасности (PSA, NetworkPolicy, сканеры), чтобы что-то заработало.
  Сначала найди причину.

## Перед коммитом

1. Затронутые линтеры и тесты проходят (`make tofu-check` и аналоги для других слоёв).
2. Изменилось поведение: обновлены README и, если нужно, ADR.
3. Изменилась версия компонента: обновлена таблица версий в README.

## Коммиты

Строго [Conventional Commits 1.0.0](https://www.conventionalcommits.org/ru/v1.0.0/).

```
<type>(<scope>): <subject>

<body: зачем, а не что>

<footer>
```

- **type**: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`, `revert`.
- **scope**: `infra`, `ansible`, `gitops`, `platform`, `app`, `monitoring`, `logging`, `ci`, `docs`,
  `tests`, `make`, `deps`. Можно уточнять: `platform/envoy-gateway`.
- **subject**: на английском, повелительное наклонение, с маленькой буквы, без точки,
  до 72 символов. `add proxmox vm module`, а не `Added Proxmox VM module.`
- **body**: по необходимости, перенос строк на 72 символах.
- Ломающее изменение: `!` после scope и футер `BREAKING CHANGE: ...`.
- Один коммит = одно логическое изменение. Форматирование отдельно от логики.
- **Запрещено**: `Co-Authored-By`, `Generated with ...`, упоминания ИИ-агентов, эмодзи.
- Не пушь без явной просьбы. Не переписывай историю `main` (`--force`, `rebase` опубликованного).

Примеры:
```
feat(infra): pin vm ssh host key in known_hosts
fix(ansible): wait for cloud-init before kubeadm init
ci: run kubeadm e2e on ubuntu-24.04 runner
docs(adr): record choice of envoy gateway
```

## Стиль текста

Касается README, ADR, паспорта, комментариев, коммитов и ответов в чате.
Пиши как инженер инженеру: коротко, конкретно, по делу.

**Нельзя**
- Длинное тире `—` и среднее `–`. Вместо них запятая, двоеточие, скобки или новое предложение.
  Дефис только внутри слов (`kube-proxy`, `app-of-apps`).
- Вода и штампы: «важно отметить», «стоит подчеркнуть», «давайте», «таким образом»,
  «в современном мире», «ключевую роль», «является неотъемлемой частью», «позволяет эффективно»,
  «надёжное и масштабируемое решение», «бесшовный», «комплексный подход».
- То же на английском: delve, leverage, seamless, robust, comprehensive, crucial, pivotal,
  "it's worth noting", "in today's world", "not just X but Y".
- Конструкции «не просто X, а Y», искусственные тройки перечислений, итоговые абзацы,
  повторяющие сказанное.
- Эмодзи, жирный шрифт через слово, восклицательные знаки, маркетинг.
- Неопределённость без причины («возможно», «как правило»). Знаешь: пиши прямо. Не знаешь: проверь.

**Нужно**
- Факты, цифры, команды, пути к файлам вместо общих слов.
- Одна мысль на предложение. Короткие абзацы.
- Простые глаголы: «ставит», «проверяет», «хранит», а не «осуществляет установку».
- Ограничения и компромиссы называй прямо.
