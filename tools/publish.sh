#!/bin/bash
# Publishes this game's pack (id game-hide-n-seek). maps/ and world/ are links into hide-n-seek-maps (its own pack; world/ is never published);
# the host ships the addons. Publish from a clean checkout of pushed HEAD (a dirty tree is packed as it is).
#   tools/publish.sh [--version V | --bump patch] [--site URL --token-file F --dry-run ...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-hide-n-seek \
    --host-addons "$HERE/../dot-server-deploy/addons.lock" --exclude-dir maps --exclude-dir world --exclude-dir art-src --exclude-dir reports --exclude-dir screenshots \
    --lock "$HERE/content.lock.json" "$@"
