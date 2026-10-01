variable "vm_name" {
  description = "VM name and hostname."
  type        = string
  default     = "mts-hack-k8s"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.vm_name))
    error_message = "vm_name: lowercase letters, digits and dashes, up to 40 chars."
  }
}

variable "vm" {
  description = "VM size. memory in MiB, disk in GiB. Defaults fit the full stack on one node."
  type = object({
    cpu    = optional(number, 4)
    memory = optional(number, 8192)
    disk   = optional(number, 30)
  })
  default = {}

  validation {
    condition     = var.vm.cpu >= 2 && var.vm.memory >= 6144 && var.vm.disk >= 25
    error_message = "vm: at least 2 vCPU, 6144 MiB RAM and 25 GiB disk are required for the stack."
  }
}

variable "vm_id" {
  description = "Proxmox VM ID. null lets Proxmox allocate one."
  type        = number
  default     = null
}

# --- Proxmox placement ---

variable "pve_node" {
  description = "Proxmox node that hosts the VM."
  type        = string
  default     = "pve"
}

variable "pve_ssh_username" {
  description = "SSH user on the Proxmox node (used only for snippet upload)."
  type        = string
  default     = "root"
}

variable "pve_ssh_address" {
  description = "Address of the Proxmox node for SSH. null = resolved by the provider from the PVE API."
  type        = string
  default     = null
}

variable "vm_datastore" {
  description = "Datastore for the VM disk and cloud-init drive."
  type        = string
  default     = "local-lvm"
}

variable "image_datastore" {
  description = "Datastore for the Ubuntu cloud image. Must have the \"Import\" content type enabled."
  type        = string
  default     = "local"
}

variable "snippets_datastore" {
  description = "Datastore for cloud-init user-data. Must have the \"Snippets\" content type enabled."
  type        = string
  default     = "local"
}

variable "cpu_type" {
  description = "QEMU CPU type. \"host\" is fastest; use x86-64-v2-AES for mixed-CPU clusters."
  type        = string
  default     = "host"
}

# --- Image ---

variable "ubuntu_image_url" {
  description = "Ubuntu 24.04 (Noble) cloud image."
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ubuntu_image_checksum" {
  description = "Optional sha256 of the image (recommended together with a dated image URL)."
  type        = string
  default     = null
}

# --- Network ---

variable "network" {
  description = "VM network. ipv4_address is \"dhcp\" or a CIDR such as 192.168.1.50/24 (static is recommended)."
  type = object({
    bridge       = optional(string, "vmbr0")
    vlan_id      = optional(number)
    ipv4_address = optional(string, "dhcp")
    gateway      = optional(string)
    dns_servers  = optional(list(string), ["1.1.1.1", "9.9.9.9"])
  })
  default = {}

  validation {
    condition = var.network.ipv4_address == "dhcp" || (
      can(cidrhost(var.network.ipv4_address, 0)) && var.network.gateway != null
    )
    error_message = "network.ipv4_address must be \"dhcp\" or a CIDR, and network.gateway is required for a static address."
  }
}

# --- Access / outputs ---

variable "ssh_public_key_path" {
  description = "Public key installed for the ubuntu user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key, written into the Ansible inventory."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_bastion" {
  description = "Optional jump host (user@host) when the VM network is not routed to the workstation."
  type        = string
  default     = null
}

variable "inventory_path" {
  description = "Where to write the generated Ansible inventory. null = ansible/inventory/generated/proxmox.yml."
  type        = string
  default     = null
}
