#!/usr/bin/env bash
# Render the game and look at it. The check no assertion in this repository makes.
#
#   tools/shot.sh --view=overview --hs-map-ids=hs_school         # a map, from above
#   tools/shot.sh --view=room --at=0,1.7,-6 --look=0,1,-14 --hs-map-ids=hs_school
#   tools/shot.sh --view=seeker                                   # a seeker's eyes, seeking
#   tools/shot.sh --view=hider --third                            # a hider from behind, in blue
#   tools/shot.sh --view=caught                                   # the moment a hider is caught
#   tools/shot.sh --view=ragdoll --seconds=0.6                    # a stand-in slain, its body 0.6 s into the fall
#   tools/shot.sh --view=bots --pick=0 --hs-map-ids=hs_manor       # the stand-ins hidden; the best-hidden one
#   tools/shot.sh --view=room --place=x,y,z --at=... --look=...     # the player stood somewhere (a branch), seen
#   tools/shot.sh --view=mapmenu --workshop                       # the M map list with a subscribed pack map in it
#   tools/shot.sh --view=door                                     # a hider at a door: the use-key prompt
#   tools/shot.sh --view=cover                                    # the loading cover, before it lifts
#   tools/shot.sh --view=blind                                    # a seeker while the hiders hide
#   tools/shot.sh --view=seeker --board                           # with the Tab scoreboard open
#   tools/shot.sh --view=room --doors=open --at=... --look=...    # every door open (or shut)
#   tools/shot.sh --view=overview --out=res://screenshots/x.png   # any --hs-* is the game's config
#
# xvfb-run because this needs a rendering context: `--headless` gives a null renderer and saves
# a frame of nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

view="seeker"
seconds="3"
out=""
config=("--hs-warmup-seconds=0" "--hs-hide-seconds=3")
extra=()

for arg in "$@"; do
    case "$arg" in
        --view=*)    view="${arg#*=}" ;;
        --seconds=*) seconds="${arg#*=}" ;;
        --out=*)     out="${arg#*=}" ;;
        --hs-*)      config+=("$arg") ;;
        --at=*|--look=*|--third|--board|--name=*|--doors=*|--pick=*|--place=*|--workshop) extra+=("$arg") ;;
        *)           echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

name="$view"
for e in "${extra[@]}"; do
    case "$e" in --name=*) name="${e#*=}" ;; esac
done
[ -n "$out" ] || out="res://screenshots/${name}.png"

exec xvfb-run -a -s "-screen 0 1280x720x24" "${GODOT:-godot}" --path . --resolution 1280x720 \
    res://tools/shot.tscn -- "--seconds=$seconds" "--view=$view" "--out=$out" "${extra[@]}" "${config[@]}"
