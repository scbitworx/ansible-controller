# ansible-controller

Controller repository for personal home infrastructure managed with Ansible.
This repo contains the main playbook, inventory, and role requirements that
drive `ansible-pull` on all hosts.

## Overview

Each host runs `ansible-pull` to clone this repository and apply configuration
locally. Roles are standalone Ansible roles hosted in separate repositories
under the `scbitworx` GitHub organization, pinned to exact versions in
`requirements.yml`.

## Prerequisites

- Ansible (installed via `scripts/bootstrap.sh` or manually)
- Git

## Bootstrap (First Run)

On a fresh host, run the bootstrap script as root:

```bash
curl -fsSL https://raw.githubusercontent.com/scbitworx/ansible-controller/main/scripts/bootstrap.sh | sudo bash
```

Or clone and run locally:

```bash
git clone https://github.com/scbitworx/ansible-controller.git
cd ansible-controller
sudo bash scripts/bootstrap.sh
```

After the first run, the `ansible-pull-wrapper` script is deployed to
`/usr/local/bin/` for subsequent invocations.

## Manual Invocation

After bootstrap, run the wrapper as root:

```bash
sudo /usr/local/bin/ansible-pull-wrapper
```

Output is logged to `/var/log/ansible-pull.log`.

## Repository Structure

```
ansible-controller/
  ansible.cfg                        # Ansible configuration
  local.yml                          # Main playbook
  requirements.yml                   # Role version pins (lockfile)
  scripts/
    bootstrap.sh                     # First-run bootstrap
    integration/                     # Integration testing (Milestone 8)
  templates/
    ansible-pull-wrapper.sh.j2       # Wrapper script template
  inventory/
    hosts.yml                        # Host inventory
    group_vars/                      # Group-level variables
    host_vars/                       # Host-level variables
```

## Hosts

| Hostname | Type    | OS         | Groups                |
| -------- | ------- | ---------- | --------------------- |
| ceres    | Laptop  | Arch Linux | workstations, laptops |
| mars     | Desktop | Arch Linux | workstations          |
| jupiter  | Server  | Arch Linux | servers               |

## Design Documentation

Architecture and design documentation lives in the planning repository.
See `CLAUDE.md` for an overview and links to detailed reference docs.
