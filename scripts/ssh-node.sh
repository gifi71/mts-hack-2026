#!/usr/bin/env bash
# Open an SSH session to the control plane node of an Ansible inventory,
# with the same key, known_hosts and jump host that Ansible uses.
#   scripts/ssh-node.sh ansible/inventory/generated/proxmox.yml [command...]
set -euo pipefail

inventory=${1:?usage: $0 <inventory> [command...]}
shift
ansible_inventory=${ANSIBLE_INVENTORY_BIN:-.venv/bin/ansible-inventory}

# stderr through a pipe: ansible refuses to run with a non-blocking stderr (some CI and IDE shells).
cmd=$("$ansible_inventory" -i "$inventory" --list 2> >(cat >&2) | python3 -c '
import json, os, shlex, sys
inv = json.load(sys.stdin)
host = inv["control_plane"]["hosts"][0]
v = inv["_meta"]["hostvars"][host]
if v.get("ansible_connection") == "local":
    print("echo This inventory targets the local machine, no SSH needed.")
    sys.exit()
args = ["ssh"]
if v.get("ansible_ssh_private_key_file"):
    args += ["-i", os.path.expanduser(v["ansible_ssh_private_key_file"])]
user = v.get("ansible_user")
target = (user + "@" if user else "") + v.get("ansible_host", host)
# ansible_ssh_common_args is already shell-quoted (ProxyCommand), keep it verbatim.
print(" ".join(map(shlex.quote, args)), v.get("ansible_ssh_common_args", ""), shlex.quote(target))
')

if (($#)); then
  eval "exec $cmd $(printf '%q ' "$@")"
else
  eval "exec $cmd"
fi
