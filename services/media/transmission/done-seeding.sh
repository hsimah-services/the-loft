#!/bin/bash
# Called by Transmission when a torrent finishes seeding (reaches ratio limit).
# Removes the torrent and deletes its data from the downloads directory.
# Safe because Radarr/Sonarr/Lidarr hardlink files to /mammoth/library.
transmission-remote 127.0.0.1:9091 --torrent "$TR_TORRENT_ID" --remove-and-delete
