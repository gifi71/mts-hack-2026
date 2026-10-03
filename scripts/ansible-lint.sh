#!/usr/bin/env bash
# ansible-lint the way CI runs it: collections from requirements.yml, production profile.
# Used by the pre-commit hook; needs ansible-core and ansible-lint on PATH.
set -euo pipefail

cd "$(dirname "$0")/../ansible"
ansible-galaxy collection install -r requirements.yml -p .ansible/collections > /dev/null
ansible-lint --profile production site.yml verify.yml info.yml
