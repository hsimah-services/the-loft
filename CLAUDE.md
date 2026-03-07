# Space-Needle Project Rules

## Environment

- `space-needle` is a **remote machine**. Claude cannot run shell commands directly on it. When diagnostics or commands are needed, provide them as text for the user to run.
- All commands that modify system state (docker, systemctl, file operations in /opt or /mammoth, etc.) must be prefixed with `sudo`.

## README Maintenance

After making any changes to the repository (docker-compose files, env files, setup.sh, space-needle-ctl, directory structure, services, etc.), review the README.md and update it to reflect the current state. This includes but is not limited to:
- Services table (images, ports, config paths, purpose)
- Storage layout (volume mounts, directories)
- Environment variables table (per-service required variables)
- Architecture description (networking, VPN routing)
- Quick start instructions and deploy commands
