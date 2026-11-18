#!/usr/bin/env bash
# Fails when a script infers a variable's type (`:=`) from a bare `identity.x` / `session.x` property read. Those
# members live in an addon class cycle (dot_net), and when the mounted pack loads in a different order the type is not
# yet known: "Cannot infer the type of <var>", then "Failed to compile depended scripts", and the game module never
# loads (pack 1.0.3, hs_player_net.gd:158). The in-project parse pass loads in another order and does not see it.
# Fix: give the variable an explicit type (`var x: bool = ...`). Run from the repo root; exit 1 on any hit.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
hits="$(grep -rnP ':=\s*[^(#]*\b(identity|session)\.\w+\b(?!\()' game examples tools --include='*.gd' 2>/dev/null)"
if [ -n "$hits" ]; then
    printf 'untyped (:=) read of an addon identity/session member, give it an explicit type:\n%s\n' "$hits"
    exit 1
fi
echo "ok: no inferred identity/session reads"
