variables {
  backend              = "test"
  hostname             = "mts-hack-k8s"
  ip                   = "10.0.0.50"
  host_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey"
  ssh_private_key_path = "/tmp/id_ed25519"
  path                 = "./.generated/test-inventory.yml"
}

run "direct_connection" {
  command = apply

  assert {
    condition     = yamldecode(local_file.inventory.content).all.children.k8s_cluster.children.control_plane.hosts["mts-hack-k8s"].ansible_host == "10.0.0.50"
    error_message = "node must be in control_plane with its address"
  }

  assert {
    condition     = strcontains(yamldecode(local_file.inventory.content).all.children.k8s_cluster.vars.ansible_ssh_common_args, "StrictHostKeyChecking=yes")
    error_message = "host key checking must stay enabled"
  }

  assert {
    condition     = !strcontains(yamldecode(local_file.inventory.content).all.children.k8s_cluster.vars.ansible_ssh_common_args, "ProxyCommand")
    error_message = "no ProxyCommand without a bastion"
  }

  assert {
    condition     = local_file.known_hosts.content == "10.0.0.50 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey\n"
    error_message = "known_hosts must pin the host key to the node address"
  }
}

run "via_bastion" {
  command = apply

  variables {
    ssh_bastion = "root@192.168.1.5"
  }

  assert {
    condition     = strcontains(yamldecode(local_file.inventory.content).all.children.k8s_cluster.vars.ansible_ssh_common_args, "-o ProxyCommand=\"ssh -i /tmp/id_ed25519 -o IdentitiesOnly=yes -W %h:%p root@192.168.1.5\"")
    error_message = "bastion must be reached with the same explicit key"
  }
}
