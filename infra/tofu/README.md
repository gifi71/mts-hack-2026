# Провижининг ВМ (OpenTofu)

Опциональный слой: создаёт на Proxmox VE одну ВМ **Ubuntu 24.04** и генерирует для Ansible
`ansible/inventory/generated/proxmox.yml` и `known_hosts`. Если у вас уже есть ВМ Ubuntu 24.04,
пропустите этот шаг и укажите её в inventory вручную.

Требования: OpenTofu >= 1.8, Proxmox VE 8.4+ (тип контента `import`), API-токен, SSH-доступ
к ноде PVE (нужен только для загрузки cloud-init snippet).

## Запуск

```bash
cp infra/tofu/proxmox/terraform.tfvars.example infra/tofu/proxmox/terraform.tfvars   # правим под себя
export PROXMOX_VE_ENDPOINT=https://<pve>:8006/
export PROXMOX_VE_API_TOKEN='tofu@pve!mts=<secret>'
export PROXMOX_VE_INSECURE=true          # самоподписанный сертификат PVE
eval "$(ssh-agent)" && ssh-add           # ключ, которым вы ходите на ноду PVE

make infra-up       # ВМ + inventory + known_hosts
make infra-output   # IP, путь к inventory, готовая ssh-команда
make infra-down     # удалить ВМ
```

Повторный `make infra-up` без изменений конфигурации ничего не меняет.
Чистый прогон с нуля: `make infra-down infra-up`.

## Подготовка Proxmox (однократно, на ноде)

```bash
# 1. Добавить типы контента snippets и import к хранилищу local.
#    Команда ЗАМЕНЯЕТ список целиком: сначала посмотрите текущий (cat /etc/pve/storage.cfg)
#    и сохраните в нём всё, что там уже есть.
pvesm set local --content iso,vztmpl,backup,snippets,import

# 2. Пользователь и API-токен для OpenTofu
pveum user add tofu@pve --comment "OpenTofu"
pveum acl modify / --users tofu@pve --roles Administrator   # homelab; в проде нужна минимальная роль
pveum user token add tofu@pve mts --privsep 0               # секрет показывается один раз
```

Диск ВМ thin-provisioned. На хранилище `vm_datastore` должно быть свободно не меньше `vm.disk`
(по умолчанию 30 GiB), иначе переполнение thin pool затронет все ВМ на нём.

## Сеть

- `network.ipv4_address`: статический адрес (`10.0.0.50/24`) или `dhcp`. Для ноды Kubernetes
  нужен статический.
- Если сеть ВМ недоступна с рабочей машины напрямую, а нода PVE доступна, задайте
  `ssh_bastion = "root@<pve>"`. Ansible пойдёт к ВМ через `ProxyCommand` с тем же ключом,
  ssh-agent не нужен.
- `pve_ssh_address` фиксирует адрес ноды PVE для SSH провайдера, когда у ноды несколько
  интерфейсов и провайдер выбирает недоступный.

## Устройство

```
infra/tofu/
├── templates/cloud-init.yaml.tftpl   # hostname, SSH-ключ, host key, qemu-guest-agent
├── modules/ansible-inventory/        # inventory + known_hosts (+ tofu test)
└── proxmox/                          # download_file + snippet + VM
```

- Host key ВМ генерирует OpenTofu (`tls_private_key`) и передаёт через cloud-init.
  Клиент проверяет его по сгенерированному `known_hosts`, поэтому `StrictHostKeyChecking=yes`
  работает и после пересоздания ВМ.
- Секреты (токен PVE) читаются только из переменных окружения. `*.tfvars`, state и
  сгенерированные файлы в git не попадают.
- Версии провайдеров зафиксированы в `versions.tf`, lock-файл коммитится.
- OpenTofu вместо Terraform: лицензия MPL-2.0 и реестр `registry.opentofu.org`, доступный из РФ.

## Ограничения

- State хранится локально. Для команды нужен remote backend (S3-совместимый или PostgreSQL).
- Приватный host key ВМ лежит в state и в snippet на ноде PVE. Для стенда это допустимо,
  в проде host key стоит выпускать через SSH CA.
- Образ `noble/current` меняется со временем. Для полной воспроизводимости задайте датированный
  URL и `ubuntu_image_checksum`.
