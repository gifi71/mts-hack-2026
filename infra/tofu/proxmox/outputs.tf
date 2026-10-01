output "vm_ip" {
  description = "IP address of the VM."
  value       = local.vm_ip
}

output "inventory_path" {
  description = "Generated Ansible inventory."
  value       = module.inventory.path
}

output "ssh_command" {
  description = "SSH into the VM with the same options Ansible uses."
  value       = "ssh -i ${pathexpand(var.ssh_private_key_path)} ${module.inventory.ssh_args} ubuntu@${local.vm_ip}"
}
