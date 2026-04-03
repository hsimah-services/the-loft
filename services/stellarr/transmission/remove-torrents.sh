#!/bin/bash

# Delete all torrents with ratio >= 2.0
transmission-remote -l | awk '
NR>1 && $1 ~ /^[0-9]+$/ {
    id=$1; ratio=$9;
    if (ratio >= 2.0) {
        print id;
    }
}' | while read id; do
    echo "Deleting torrent $id (ratio >= 2.0)"
    transmission-remote --torrent "$id" --remove-and-delete
done
