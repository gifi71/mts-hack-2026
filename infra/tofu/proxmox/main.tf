locals {
  static         = var.network.ipv4_address != "dhcp"
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "tls_private_key" "host_key" {
  algorithm = "ED25519"
}

resource "proxmox_download_file" "ubuntu_noble" {
  node_name          = var.pve_node
  datastore_id       = var.image_datastore
  content_type       = "import"
  file_name          = "noble-server-cloudimg-amd64.qcow2"
  url                = var.ubuntu_image_url
  checksum           = var.ubuntu_image_checksum
  checksum_algorithm = var.ubuntu_image_checksum == null ? null : "sha256"
  # "current" is a moving target: do not re-download (and churn the VM) on every apply.
  overwrite = false
}

resource "proxmox_virtual_environment_file" "user_data" {
  node_name    = var.pve_node
  datastore_id = var.snippets_datastore
  content_type = "snippets"

  source_raw {
    file_name = "${var.vm_name}-user-data.yaml"
    data = templatefile("${path.module}/../templates/cloud-init.yaml.tftpl", {
      hostname         = var.vm_name
      ssh_public_key   = local.ssh_public_key
      host_key_private = tls_private_key.host_key.private_key_openssh
      host_key_public  = tls_private_key.host_key.public_key_openssh
      packages         = ["qemu-guest-agent"]
    })
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  name        = var.vm_name
  node_name   = var.pve_node
  vm_id       = var.vm_id
  description = "Single-node Kubernetes (kubeadm) for MTC ENGINEER HACK 2026. Managed by OpenTofu."
  tags        = ["k8s", "mts-hack"]

  machine         = "q35"
  on_boot         = true
  started         = true
  stop_on_destroy = true

  agent {
    enabled = true
    timeout = "15m"
  }

  cpu {
    cores = var.vm.cpu
    type  = var.cpu_type
  }

  memory {
    dedicated = var.vm.memory
  }

  operating_system {
    type = "l26"
  }

  # Ubuntu cloud images log to the serial console.
  serial_device {}

  disk {
    datastore_id = var.vm_datastore
    import_from  = proxmox_download_file.ubuntu_noble.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.vm.disk
  }

  network_device {
    bridge  = var.network.bridge
    vlan_id = var.network.vlan_id
    model   = "virtio"
  }

  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = var.network.ipv4_address
        gateway = local.static ? var.network.gateway : null
      }
    }

    dns {
      servers = var.network.dns_servers
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data.id
  }
}

locals {
  # Static address when configured, otherwise the first non-loopback address reported by the guest agent.
  vm_ip = local.static ? split("/", var.network.ipv4_address)[0] : [
    for ip in flatten(proxmox_virtual_environment_vm.node.ipv4_addresses) : ip if !startswith(ip, "127.")
  ][0]
}

module "inventory" {
  source = "../modules/ansible-inventory"

  backend              = "proxmox"
  hostname             = var.vm_name
  ip                   = local.vm_ip
  host_public_key      = tls_private_key.host_key.public_key_openssh
  ssh_private_key_path = var.ssh_private_key_path
  ssh_bastion          = var.ssh_bastion
  path                 = coalesce(var.inventory_path, "${path.root}/../../../ansible/inventory/generated/proxmox.yml")
}
