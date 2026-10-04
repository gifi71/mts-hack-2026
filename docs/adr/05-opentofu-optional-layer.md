---
status: принято
date: 2026-10-02
deciders: Павел Дудко
related: [ADR-01]
---

# 05. OpenTofu как опциональный слой, Proxmox

> **Коротко.** В контексте разработки на своём Proxmox, столкнувшись с тем, что эксперты не имеют доступа к
> инфраструктуре автора, выбрали OpenTofu с провайдером bpg как опциональный слой, который создаёт одну ВМ
> и пишет inventory, и не стали брать Terraform и непроверенные пути вроде Multipass, чтобы автор
> пересоздавал ВМ одной командой, а основной путь эксперта от этого слоя не зависел, приняв локальный state
> и поддержку только Proxmox.

## Контекст и проблема

Как автору быстро получать чистую ВМ для прогона «с нуля», не навязывая свою инфраструктуру экспертам?
Эксперты разворачивают решение на своей ВМ, к Proxmox автора доступа у них нет. Решение затрагивает
`infra/tofu/`, цели `infra-*` и `tofu-check` в `Makefile`, сгенерированный `ansible/inventory/generated/`.

## Требования и ограничения

- Решение воспроизводится без доступа к инфраструктуре участника (docs/task/case.md, «Задание кратко»).
- Terraform, Ansible и иные open-source инструменты разрешены (docs/task/case.md, «Автоматизация развертывания»).
- Нужно автоматизировать путь от чистой ВМ до кластера (docs/task/qa.md). Сама ВМ у эксперта своя.
- Прогон «с нуля» перед тем, как считать этап готовым: ВМ пересоздаётся часто.
- SSH к ВМ без отключения проверки host key, в том числе после пересоздания.

## Рассмотренные варианты

1. OpenTofu, опциональный слой для Proxmox
2. Terraform
3. Multipass или libvirt как путь для экспертов

## Решение

Выбран вариант «OpenTofu, опциональный слой», потому что он даёт автору пересоздание ВМ одной командой и
не добавляет шагов в основной путь эксперта (готовая ВМ и `make deploy`).

- Root-модуль `infra/tofu/proxmox`: провайдер `bpg/proxmox` 0.114.0 (`~> 0.114.0`, lock-файл закоммичен),
  провайдеры берутся из `registry.opentofu.org`. Учётные данные Proxmox только из переменных окружения
  `PROXMOX_VE_*`.
- Создаётся одна ВМ Ubuntu 24.04 из cloud image (`proxmox_download_file`) с cloud-init
  (`infra/tofu/templates/cloud-init.yaml.tftpl`): hostname, SSH-ключ пользователя, `qemu-guest-agent`.
- Host key ВМ (ED25519) генерирует `tls_private_key` и передаёт через cloud-init (`ssh_keys`), поэтому
  ключ известен до первого подключения.
- Модуль `infra/tofu/modules/ansible-inventory` пишет `ansible/inventory/generated/proxmox.yml` и
  `known_hosts` рядом с ним. SSH-опции Ansible: `StrictHostKeyChecking=yes`, `UserKnownHostsFile` на этот
  файл, опционально bastion через `ProxyCommand`.

### Последствия

- Плюс: цикл автора «с нуля» одной строкой: `make infra-down infra-up deploy verify`.
- Плюс: `StrictHostKeyChecking=yes` работает и после пересоздания ВМ, правка `known_hosts` руками не нужна.
- Минус: state локальный. Для работы в команде нужен remote backend.
- Минус: поддержан только Proxmox. На другой платформе эксперт готовит ВМ сам.
- Нейтрально: образ по умолчанию берётся из `noble/current` без checksum. Для воспроизводимого образа
  задаются датированный URL и `ubuntu_image_checksum`.

### Как проверяется

- CI: workflow `ci`, job «lint and validate», шаг «OpenTofu validate, test» (`make tofu-check`): `tofu fmt -check`,
  `tofu validate` root-модуля и `tofu test` модуля inventory. Тесты проверяют адрес хоста,
  `StrictHostKeyChecking=yes`, содержимое `known_hosts` и `ProxyCommand` для bastion.
- pre-commit: хук `tofu fmt`.
- Создание ВМ на Proxmox автоматически не проверяется: в CI нет Proxmox. Проверено вручную на стенде автора.

## Плюсы и минусы вариантов

### Terraform

- Плюс: больше примеров и готовых модулей.
- Минус: лицензия BSL.
- Минус: реестр `registry.terraform.io` блокирует запросы из РФ.

### Multipass или libvirt для экспертов

- Плюс: эксперт получил бы ВМ одной командой.
- Минус: автор не может проверить эти пути на своей машине, а непроверенный путь в README хуже отсутствующего.

## Когда пересмотреть

- Над стендом работает больше одного человека: нужен remote backend для state.
- Нужен второй провайдер (облако или libvirt), который можно проверить в CI.

## Ссылки

- Код: `infra/tofu/proxmox/`, `infra/tofu/modules/ansible-inventory/`, `infra/tofu/templates/cloud-init.yaml.tftpl`
- Связанные ADR: ADR-01
- Требования: [docs/task/case.md](../task/case.md), [docs/task/qa.md](../task/qa.md)
- Документация: <https://registry.opentofu.org/providers/bpg/proxmox/latest/docs>
