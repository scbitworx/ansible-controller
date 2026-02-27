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
- `pass` (password-store) with an initialized store
- `gpg` with a valid key pair
- Pass entry `scbitworx/vault-password` containing the Ansible Vault password

## Bootstrap (First Run)

Before running the bootstrap script, set up the vault prerequisites:

```bash
# Install pass and gpg (if not already installed)
# Arch: pacman -S pass gnupg
# Debian/Ubuntu: apt-get install pass gnupg

# Initialize the pass store (if not already done)
pass init <your-gpg-key-id>

# Add the vault password
pass insert scbitworx/vault-password
```

Then run the bootstrap script as root:

```bash
curl -fsSL https://raw.githubusercontent.com/scbitworx/ansible-controller/main/scripts/bootstrap.sh | sudo bash
```

Or clone and run locally:

```bash
git clone https://github.com/scbitworx/ansible-controller.git
cd ansible-controller
sudo bash scripts/bootstrap.sh
```

The bootstrap script checks that `pass`, `gpg`, and the vault password entry
exist before proceeding. It deploys an inline vault client for the first run;
subsequent runs use the templated version at `/usr/local/bin/ansible-vault-client`.

After the first run, the `ansible-pull-wrapper` script is deployed to
`/usr/local/bin/` for subsequent invocations.

## Manual Invocation

After bootstrap, run the wrapper (it re-execs as root via sudo automatically):

```bash
/usr/local/bin/ansible-pull-wrapper
```

Output is logged to `/var/log/ansible-pull.log`.

## Vault Helper Scripts

The playbook deploys four helper scripts to `/usr/local/bin/`:

| Script | Purpose |
|--------|---------|
| `ansible-vault-client` | Retrieves the vault password from `pass`. Used by `--vault-id` |
| `ansible-vault-secret` | Encrypts a string as a vault variable. Usage: `ansible-vault-secret <var_name> <value>` |
| `ansible-vault-reveal` | Decrypts a variable from a YAML file. Usage: `ansible-vault-reveal <var_name> <file>` |
| `ansible-mkpasswd` | Generates SHA-512 password hashes interactively (hidden input, confirm) |

## Repository Structure

```
ansible-controller/
  ansible.cfg                        # Ansible configuration
  local.yml                          # Main playbook
  requirements.yml                   # Role version pins (lockfile)
  scripts/
    bootstrap.sh                     # First-run bootstrap
    integration/                     # Integration testing (see below)
  templates/
    ansible-pull-wrapper.sh.j2       # Wrapper script template
    ansible-vault-client.sh.j2       # Vault password client (pass backend)
    ansible-vault-secret.sh.j2       # Encrypt-a-string helper
    ansible-vault-reveal.sh.j2       # Decrypt-and-display helper
    ansible-mkpasswd.sh.j2           # Interactive password hash generator
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

## Integration Testing

Integration tests validate the full controller pipeline end-to-end on
disposable libvirt VMs. Tests are **never** run against production hosts.

### Prerequisites

Install the following on your workstation:

- `libvirt`, `qemu` — VM hypervisor
- `virt-install`, `virt-customize`, `virt-resize` — VM provisioning tools
- `qemu-img` — disk image management
- `cdrtools` (Arch) or `genisoimage` (Debian/Ubuntu) — cloud-init seed ISO
- `nftables` — firewall (for Docker FORWARD chain workaround)

On Arch Linux:

```bash
pacman -S libvirt qemu-full virt-install guestfs-tools qemu-img cdrtools nftables
```

### Setup

Generate the test GPG key (one-time, committed to the repo):

```bash
scripts/integration/generate-test-gpg-key.sh
```

Create the test VM (downloads the Arch cloud image on first run):

```bash
scripts/integration/create-base-vms.sh
```

This creates a `test-archlinux` VM on the default NAT network (`virbr0`),
injects a test SSH key, and takes a `clean` snapshot for test isolation.

### Running Tests

Run the full test suite:

```bash
scripts/integration/run-all.sh
```

Or run individual steps:

```bash
# Revert to clean snapshot, bootstrap, verify, and check idempotency
scripts/integration/run-integration-test.sh

# Run only the 22-assertion state verification
scripts/integration/verify-state.sh
```

### What Gets Tested

The test pipeline runs three checks:

1. **Bootstrap** — `bootstrap.sh` installs Ansible and runs the initial pull
   against `inventory/test-hosts.yml`
2. **State verification** — 22 assertions covering admin user, SSH hardening,
   timezone, base packages, ansible-pull timer, vault scripts, and
   distro-specific behavior
3. **Idempotency** — a second `ansible-pull` run produces zero changes

### Test Isolation

Each test run reverts the VM to its `clean` snapshot, ensuring a fresh
starting state. The VM can be destroyed and recreated at any time with
`create-base-vms.sh`.

Test artifacts are stored in `scripts/integration/testdata/`:

- `test-gpg-key.asc` — test-only GPG key (committed, protects nothing real)
- `id_ed25519` / `id_ed25519.pub` — test SSH keypair
- `Arch-Linux-x86_64-cloudimg.qcow2` — cached cloud image (gitignored)

### Docker + libvirt Note

Docker's FORWARD chain can drop `virbr0` traffic. `create-base-vms.sh` adds
nftables forwarding rules automatically, but they do not persist across
reboots. If VM networking stops working after a reboot, re-run
`create-base-vms.sh`.

## Design Documentation

Architecture and design documentation lives in the planning repository.
See `CLAUDE.md` for an overview and links to detailed reference docs.
