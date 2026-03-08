# The Loft Project Rules

## Environment

- The Loft hosts are **remote machines**. Claude cannot run shell commands directly on them. When diagnostics or commands are needed, provide them as text for the user to run.
- All commands that modify system state (docker, systemctl, file operations in /opt or /mammoth, etc.) must be prefixed with `sudo`.

## Fleet Structure

- Host configs live at `hosts/<hostname>/host.conf` (bash-sourceable)
- Service definitions live at `services/<name>/docker-compose.yml`
- Per-host overrides live at `hosts/<hostname>/overrides/<service>/docker-compose.override.yml`
- Control-plane scripts live at `control-plane/` and source host.conf dynamically
- `loft-ctl` is the fleet-aware control script (aliased in bashrc, backward-compat alias `space-needle-ctl`)
- `setup.sh` is the unified host provisioner — reads `hosts/$(hostname)/host.conf`

## README Maintenance

After making any changes to the repository (docker-compose files, env files, setup.sh, loft-ctl, host configs, directory structure, services, etc.), review the README.md and update it to reflect the current state. This includes but is not limited to:
- Services table (images, ports, config paths, purpose)
- Storage layout (volume mounts, directories)
- Environment variables table (per-service required variables)
- Architecture description (fleet, hosts, networking)
- Quick start instructions and deploy commands
- Host configuration format
