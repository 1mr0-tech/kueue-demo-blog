#!/usr/bin/env bash
# runs the demo one command at a time, press enter to run each one
#
#   scripts/demo.sh      start from act 1 (resets the cluster first)
#   scripts/demo.sh 4    quietly replay acts 1-3, then pick up at act 4
#
# grey lines are just notes for me, they don't run anything
set -uo pipefail
cd "$(dirname "$0")/.."

START=${1:-1}
FAST=0  # 1 while replaying earlier acts

C_CMD="\033[1;32m" C_CUE="\033[2;3m" C_ACT="\033[1;45;97m" R="\033[0m"

act()  { [ $FAST = 1 ] && return; clear; printf "\n${C_ACT}  ACT %s  ${R}  \033[1m%s\033[0m\n\n" "$1" "$2"; }
cue()  { [ $FAST = 1 ] && return; printf "${C_CUE}  # %s${R}\n" "$*"; }
pause(){ [ $FAST = 1 ] && return; read -rsp $'' _; }
run() {
  if [ $FAST = 1 ]; then eval "$*" >/dev/null 2>&1; return; fi
  printf "${C_CMD}\$ %s${R}" "$*"; read -rs _; echo
  eval "$*"
  echo
}
# poll until the check passes so I never show a half-updated state
wait_for() {
  local msg=$1; shift
  [ $FAST = 0 ] && printf "${C_CUE}  ... %s${R}" "$msg"
  until eval "$*" >/dev/null 2>&1; do [ $FAST = 0 ] && printf '.'; sleep 1; done
  [ $FAST = 0 ] && echo " done"
}
admitted() { # admitted <ns> <job>
  kubectl get workloads -n "$1" -o json | python3 -c "
import json,sys
for w in json.load(sys.stdin)['items']:
    if any(o['name']=='$2' for o in w['metadata'].get('ownerReferences',[])):
        sys.exit(0 if any(c['type']=='Admitted' and c['status']=='True' for c in w['status'].get('conditions',[])) else 1)
sys.exit(1)"
}
not_admitted() { ! admitted "$@"; }
WL='kubectl get workloads -A'
EVENTS() { kubectl get events -n "$1" --sort-by=.lastTimestamp -o custom-columns=REASON:.reason,MESSAGE:.message | grep -E "$2" | tail -${3:-1} | cut -c1-220; }

act1() {
  act 1 "Chaos: a shared GPU cluster with no rules"
  cue "8 GPUs, 2 nodes, 2 teams. Kubernetes' scheduler is first-come, first-served."
  run "kubectl get nodes -l accelerator -o 'custom-columns=NODE:.metadata.name,GPUS:.status.allocatable.nvidia\\.com/gpu'"
  cue "Research launches a 6-GPU hyperparameter sweep. Nothing stops them."
  run "kubectl apply -f demo/act1-chaos/research-sweep.yaml"
  cue "Production needs a 4-worker distributed fine-tune. 2 GPUs are left..."
  run "kubectl apply -f demo/act1-chaos/llm-finetune.yaml"
  wait_for "scheduling" "[ \$(kubectl get pods -n production --field-selector=status.phase=Running -o name | wc -l) -ge 2 ]"
  run "kubectl get pods -n production"
  cue "2 workers running, 2 Pending. A distributed job can't train with half its ranks."
  cue "So 2 GPUs are burning money doing NOTHING, and research can't use them either."
  run "EVENTS production FailedScheduling"
  cue "Who gets GPUs? Whoever clicked first. Nobody has a guarantee. Let's fix that."
  run "kubectl delete jobs --all -n research; kubectl delete jobs --all -n production"
}

act2() {
  act 2 "Kueue: quotas and queues"
  cue "Three objects. ResourceFlavor = what hardware we have."
  run "cat manifests/queues/10-flavor.yaml"
  cue "ClusterQueue = a team's guaranteed slice. 4 GPUs each."
  run "cat manifests/queues/20-clusterqueues.yaml | head -24"
  cue "LocalQueue = the namespaced front door teams submit to. Plus two priorities for later."
  run "kubectl apply -f manifests/queues/"
  cue "The only change for users: one label on the Job."
  run "grep -n -B1 -A2 queue-name demo/act2-queues/llm-finetune.yaml"
  cue "Research submits 3 experiments x 2 GPUs = 6 GPUs. Their quota is 4."
  run "kubectl apply -f demo/act2-queues/research-experiments.yaml"
  cue "Production submits the same 4-GPU fine-tune as before."
  run "kubectl apply -f demo/act2-queues/llm-finetune.yaml"
  wait_for "admitting" "admitted production llm-finetune && admitted research research-exp-2"
  run "$WL"
  run "kubectl get jobs -n research"
  cue "exp-3 is Suspended: zero pods, zero GPUs held. It just waits its turn."
  cue "Production got all 4 workers at once. Guaranteed quota; nobody can take it."
}

act3() {
  act 3 "Borrowing: idle GPUs are wasted GPUs"
  cue "Production's fine-tune finishes."
  run "kubectl delete job llm-finetune -n production"
  cue "Now 4 GPUs sit idle... while research-exp-3 is still waiting. Strict quotas waste money."
  run "kubectl get workloads -n research"
  cue "Put both teams in a cohort: they may borrow each other's unused quota."
  run "diff manifests/queues/20-clusterqueues.yaml demo/act3-borrow/clusterqueues-cohort.yaml | grep '^>' | head -8"
  run "kubectl apply -f demo/act3-borrow/clusterqueues-cohort.yaml"
  wait_for "borrowing" "admitted research research-exp-3"
  run "kubectl get workloads -n research"
  run "kubectl get clusterqueue research -o jsonpath='{range .status.flavorsReservation[0].resources[?(@.name==\"nvidia.com/gpu\")]}GPUs in use: {.total}   borrowed: {.borrowed}{\"\\n\"}{end}'"
}

act4() {
  act 4 "Reclaim: lending is not giving away"
  cue "Production needs its GPUs back. Same fine-tune, resubmitted."
  run "kubectl apply -f demo/act2-queues/llm-finetune.yaml"
  wait_for "reclaiming" "admitted production llm-finetune"
  run "$WL"
  cue "Kueue evicted ONLY the borrowed workload and requeued it. Why? Kueue tells you:"
  run "EVENTS research 'Preempted'"
  cue "No pager, no Slack thread, no 'can you please kill your job'."
}

act5() {
  act 5 "Priority: the release blocker"
  cue "Production's GPUs are full with the batch-priority fine-tune. Incident: urgent eval needed NOW."
  run "grep -E 'priority-class' demo/act5-priority/hotfix-eval.yaml"
  run "kubectl apply -f demo/act5-priority/hotfix-eval.yaml"
  wait_for "preempting" "admitted production hotfix-eval"
  wait_for "spare GPUs" "admitted research research-exp-3"
  run "$WL"
  run "EVENTS production 'prioritization'"
  cue "And the 2 GPUs the hotfix didn't need? Look: research borrowed them. Zero idle GPUs."
  pause
  cue "Hotfix done."
  run "kubectl delete job hotfix-eval -n production"
  wait_for "fine-tune coming back" "admitted production llm-finetune"
  run "$WL"
  cue "The fine-tune came back by itself and reclaimed its GPUs. Nobody touched anything."
}

act6() {
  act 6 "All-or-nothing: no half-started jobs"
  run "scripts/reset-jobs.sh"
  cue "A GPU node fails its health check and gets cordoned."
  run "kubectl cordon k3d-ai-cluster-agent-1"
  cue "Production submits a 6-worker pretraining job. Quota says yes (borrowing). Hardware says only 4 fit."
  run "kubectl apply -f demo/act6-gang/distributed-pretrain.yaml"
  wait_for "scheduling" "[ \$(kubectl get pods -n production --field-selector=status.phase=Running -o name | wc -l) -ge 4 ]"
  run "kubectl get pods -n production"
  cue "Same mess as Act 1... but Kueue has waitForPodsReady (45s here, ~10 min in real life)."
  wait_for "waiting for the PodsReady timeout" "not_admitted production distributed-pretrain"
  run "EVENTS production 'PodsReady'"
  run "kubectl get pods -n production"
  cue "Evicted as a unit: all 6 GPUs released, job requeued with backoff. Node gets fixed:"
  run "kubectl uncordon k3d-ai-cluster-agent-1"
  wait_for "requeue backoff, then re-admission" "admitted production distributed-pretrain && [ \$(kubectl get pods -n production --field-selector=status.phase=Running -o name | wc -l) -ge 6 ]"
  run "kubectl get pods -n production"
}

act7() {
  act 7 "See it: queue positions and KueueViz"
  run "scripts/reset-jobs.sh"
  cue "Friday evening: research queues 6 experiments x 2 GPUs = 12 GPUs. The cluster has 8."
  run "kubectl apply -f demo/act7-visibility/research-backlog.yaml"
  wait_for "admitting" "[ \$(kubectl get workloads -n research --no-headers | grep -c True) -ge 4 ]"
  cue "Production is idle, so research borrows the whole cluster: 8/8 GPUs busy."
  cue "'Where is my job?' The visibility API gives every pending job its position:"
  run "scripts/queue-positions.sh research"
  cue "Now the browser: scripts/kueueviz.sh (already running). Show the cohort, the borrowed quota, the queue."
}

# main
scripts/reset.sh
for n in 1 2 3 4 5 6 7; do
  [ "$n" -lt "$START" ] && FAST=1 || FAST=0
  [ $FAST = 1 ] && echo "replaying act $n..."
  "act$n"
  [ $FAST = 0 ] && { printf "\n${C_CUE}  (Enter for next act)${R}"; read -rs _; }
done
clear; printf "\n  \033[1mThat's the demo.\033[0m Back to slides.\n\n"
