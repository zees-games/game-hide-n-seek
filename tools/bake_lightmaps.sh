#!/usr/bin/env bash
# Bake the maps' light: one lightmaps/<id>.res per map, which a client lays over the map it builds (HsMap._attach_bake; dot-map's
# DotMapBoxBake over dot-lighting's DotLightBake).
#
#   tools/bake_lightmaps.sh                    # every map
#   tools/bake_lightmaps.sh hs_mall hs_school  # these
#   GPU_BOX=staging02 tools/bake_lightmaps.sh  # on the desktop's RTX 2070 (default: the laptop)
#
# Two steps on the GPU box through ../gpu.sh: tools/lightmap_scenes.tscn writes a bake scene per map into lightbake_work/, then the editor bakes
# them (dot-lighting's editor plugin, enabled in project.godot and inert without its flag; Forward+ on Vulkan). lightmaps/ is copied back.
# Commit lightmaps/ afterwards: a map changed without a rebake is drawn with live lamps and a WARN until it is baked again.
set -euo pipefail
cd "$(dirname "$0")/.."
project="$(basename "$PWD")"
maps=$(IFS=,; echo "$*")
scenes=(res://tools/lightmap_scenes.tscn -- --out=res://lightbake_work ${maps:+--maps=$maps})
bake=(--editor --rendering-method forward_plus -- --dot-bake-lightmaps=res://lightbake_work)
log=.godot/dot-light-bake.log
mkdir -p .godot lightmaps
rm -rf lightbake_work
rc=0; timeout "${GPU_SCENES_TIMEOUT:-900}" ../gpu.sh run "$project" "${scenes[@]}" > "$log.scenes" 2>&1 || rc=$?
grep -E '^LIGHTMAP_SCENE|ERROR' "$log.scenes" || true
[[ $rc -eq 0 ]] || { echo "writing the scenes failed (exit $rc), see $log.scenes" >&2; exit 1; }
# No sync between the steps: the scenes were written there, and a sync would delete them.
../gpu.sh exec timeout "${GPU_TIMEOUT:-1800}" xvfb-run -a -s "-screen 0 1280x720x24" \
    gpu/bin/godot --path "gpu/godot/$project" --rendering-driver vulkan --gpu-index "${GPU_INDEX:-0}" \
    "${bake[@]}" > "$log" 2>&1 || true
../gpu.sh pull "$project" lightmaps
grep -E '^DOT_BAKE' "$log" || true
ls -l lightmaps/
