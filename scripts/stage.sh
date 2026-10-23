#!/usr/bin/env bash
# tmux layout for the talk
#   left:  demo.sh
#   right: status.py (live view of gpus, queues, workloads)
#   window 1 (ctrl-b 1): kueueviz port-forward, http://localhost:8080
# bump the terminal font up to ~20pt first or the back row sees nothing
set -euo pipefail
cd "$(dirname "$0")/.."
SESSION=kueue-demo
tmux kill-session -t $SESSION 2>/dev/null || true
tmux new-session -d -s $SESSION -n demo -x "$(tput cols)" -y "$(tput lines)"
tmux set -t $SESSION status off
tmux set -t $SESSION mouse on
tmux send-keys -t $SESSION:demo "clear; echo 'Press Enter to start: scripts/demo.sh ${1:-}'; read; scripts/demo.sh ${1:-}" C-m
tmux split-window -h -p 48 -t $SESSION:demo "scripts/status.py"
tmux select-pane -t $SESSION:demo.0
tmux new-window -d -t $SESSION -n viz "scripts/kueueviz.sh"
exec tmux attach -t $SESSION
