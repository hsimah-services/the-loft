---
name: Loft host repo path
description: The path where the-loft repo lives on remote hosts
type: project
---

The loft repo is deployed to `/srv/the-loft` on remote hosts (not `/opt/the-loft`).

**Why:** Correction from user after Claude used wrong path.
**How to apply:** All docker compose commands and file references on remote hosts should use `/srv/the-loft/...`.
