# 0005. OpenTofu как опциональный слой, Proxmox

## Контекст

Эксперты не имеют доступа к инфраструктуре автора. Автор тестирует на своём Proxmox и хочет пересоздавать
ВМ одной командой.

## Решение

- **OpenTofu** создаёт одну ВМ Ubuntu 24.04 на Proxmox (провайдер bpg), cloud-init, генерирует
  Ansible inventory и `known_hosts`.
- Host key ВМ генерируется OpenTofu и передаётся через cloud-init, поэтому `StrictHostKeyChecking=yes`
  работает и после пересоздания.
- Слой опциональный: основной путь для эксперта (готовая ВМ + `make deploy`) от него не зависит.

## Варианты

- **Terraform**: лицензия BSL, реестр `registry.terraform.io` блокирует запросы из РФ.
- **Multipass / libvirt для экспертов**: автор не может проверить их на своей машине, а непроверенный путь
  в README хуже отсутствующего.

## Последствия

- Цикл автора «с нуля»: `make infra-down infra-up deploy verify`.
- State локальный. Для команды нужен remote backend.
