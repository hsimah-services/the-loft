#!/usr/bin/env python3
# Shared by any i3 dashboard host (calavera, viking, ...). Deployed by
# hosts/<host>/bootstrap to /usr/local/bin/loft-dashboard-power and driven by
# host-specific config in /etc/default/loft-dashboard-power (LOFT_POWER_GROUPS
# etc — see hosts/<host>/host.conf's I3_POWER_GROUPS).
#
# Turns the display on the instant any of this host's configured Music
# Assistant groups starts playing, and off after LOFT_POWER_IDLE_SECS of no
# playback AND no local input (xprintidle) — so it doesn't blank while
# someone's actively browsing the dashboard between tracks.

import asyncio
import json
import logging
import os
import subprocess

import websockets

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("loft-dashboard-power")

MA_WS_URL = os.environ.get("LOFT_POWER_MA_WS", "ws://192.168.86.28:8095/ws")
GROUPS = {g.strip() for g in os.environ.get("LOFT_POWER_GROUPS", "").split(",") if g.strip()}
IDLE_SECS = int(os.environ.get("LOFT_POWER_IDLE_SECS", "600"))
POLL_SECS = 15
RECONNECT_MAX_SECS = 30

group_states = {name: "idle" for name in GROUPS}
screen_on = True


def set_screen(on: bool) -> None:
    global screen_on
    if on == screen_on:
        return
    subprocess.run(["xset", "dpms", "force", "on" if on else "off"], check=False)
    screen_on = on
    log.info("screen %s", "on" if on else "off")


def is_streaming() -> bool:
    return any(state == "playing" for state in group_states.values())


def idle_ms() -> int:
    try:
        return int(subprocess.check_output(["xprintidle"], text=True).strip())
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        return 0


async def idle_watch() -> None:
    while True:
        await asyncio.sleep(POLL_SECS)
        if not is_streaming() and idle_ms() >= IDLE_SECS * 1000:
            set_screen(False)


async def listen() -> None:
    backoff = 1
    while True:
        try:
            async with websockets.connect(MA_WS_URL) as ws:
                log.info(
                    "connected to %s, watching groups: %s",
                    MA_WS_URL,
                    ", ".join(sorted(GROUPS)) or "(none configured)",
                )
                backoff = 1
                async for raw in ws:
                    msg = json.loads(raw)
                    if msg.get("event") != "player_updated":
                        continue
                    data = msg.get("data", {})
                    name = data.get("display_name") or data.get("name")
                    if name not in GROUPS:
                        continue
                    state = data.get("playback_state") or data.get("state")
                    group_states[name] = state
                    log.info("%s -> %s", name, state)
                    if state == "playing":
                        set_screen(True)
        except (OSError, websockets.exceptions.WebSocketException) as exc:
            log.warning("ws connection lost (%s), retrying in %ss", exc, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, RECONNECT_MAX_SECS)


async def main() -> None:
    if not GROUPS:
        log.warning("LOFT_POWER_GROUPS is empty; screen will only ever turn off on idle, never wake on playback")
    await asyncio.gather(listen(), idle_watch())


if __name__ == "__main__":
    asyncio.run(main())
