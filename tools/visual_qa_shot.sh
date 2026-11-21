#!/usr/bin/env bash
# Visual QA capture on a GPU box (addons/gs_game/docs/visual-qa.md). Shared driver: gs-game.
exec bash "$(dirname "$0")/../addons/gs_game/tools/gs_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
