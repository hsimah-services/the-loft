# The Loft Project Rules

## Environment

- The Loft hosts are **remote machines**. Claude cannot run shell commands directly on them. When diagnostics or commands are needed, provide them as text for the user to run.
- All commands that modify system state (docker, systemctl, file operations in /opt or /mammoth, etc.) must be prefixed with `sudo`.

## Fleet Structure

- Host configs live at `hosts/<hostname>/host.conf` (bash-sourceable)
- Service definitions live at `services/<name>/docker-compose.yml`
- Per-host overrides live at `hosts/<hostname>/overrides/<service>/docker-compose.override.yml`
- `control-plane/common.sh` has shared helpers (compose_args_for, health checks) sourced by loft-ctl and setup.sh
- `loft-ctl` is the fleet-aware control script (aliased in bashrc) with commands: start, stop, rebuild, health, update
- `setup.sh` is the unified host provisioner — reads `hosts/$(hostname)/host.conf`

## README Maintenance

After making any changes to the repository (docker-compose files, env files, setup.sh, loft-ctl, host configs, directory structure, services, etc.), review the README.md and update it to reflect the current state. This includes but is not limited to:
- Services table (images, ports, config paths, purpose)
- Storage layout (volume mounts, directories)
- Environment variables table (per-service required variables)
- Architecture description (fleet, hosts, networking)
- Quick start instructions and deploy commands
- Host configuration format

## Naming Conventions

When suggesting names for new services or hosts, follow these conventions.

### Service Names
Service names are creative, single-word names inspired by two theme pools:

- **Space / aerospace**: Rockets, planets, stars, celestial phenomena (quasars, pulsars, nebulae), space missions, cosmonauts, satellites, orbital mechanics terms
- **Dogs / spitz breeds**: Husky, Pomeranian, Samoyed, Akita, Malamute, and other spitz-type breeds; sled dog culture (mushing, races, commands); dog behaviors and traits

Names should feel like a natural mashup or wordplay connecting the theme to what the service does, not a literal description. Examples of existing names and their reasoning:
- **howlr** — audio streaming; huskies howl (dog theme)
- **iditarod** — CI runner; Iditarod is a sled dog race, runners run (dog theme)
- **pupyrus** — WordPress site; puppy + papyrus, a writing surface (dog theme)
- **laiko** / **belki** — the owner's pomskies, named after Laika and Belka, dogs launched into space (both themes)

When asked for naming suggestions, offer a few options from each theme pool with a brief note on the wordplay.

### Host / Machine Names
Host names are inspired by **something physically visible** from the owner's location — landmarks, objects on a shelf, artwork, etc. Examples:
- **space-needle** — the Seattle landmark visible from the desk
- **viking** / **fjord** — from a bottle of Vikingfjord vodka on the bar

When suggesting host names, ask the user what they can see around them and riff on that.

### Container Names Within Services
- Multi-container services prefix each container with the service name: `howlr-snapserver`, `pupyrus-db`
- Single-container services use the service name directly: `plex`, `iditarod`
