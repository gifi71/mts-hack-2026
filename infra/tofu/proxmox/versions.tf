terraform {
  required_version = ">= 1.8.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.114.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Credentials are read from the environment only (never stored in the repo):
#   PROXMOX_VE_ENDPOINT   e.g. https://192.168.1.5:8006/
#   PROXMOX_VE_API_TOKEN  e.g. tofu@pve!mts=xxxxxxxx-xxxx-...
#   PROXMOX_VE_INSECURE   true when PVE uses a self-signed certificate
# SSH (agent) is required only to upload the cloud-init snippet.
provider "proxmox" {
  ssh {
    agent    = true
    username = var.pve_ssh_username

    # The provider resolves the node address from the PVE API and may pick an
    # interface the workstation cannot reach. Pin it when needed.
    dynamic "node" {
      for_each = var.pve_ssh_address == null ? [] : [var.pve_ssh_address]
      content {
        name    = var.pve_node
        address = node.value
      }
    }
  }
}
