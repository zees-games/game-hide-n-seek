#!/usr/bin/env bash
# Visual QA capture on a GPU box (addons/dot_game/docs/visual-qa.md). Shared driver: dot-game.
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
