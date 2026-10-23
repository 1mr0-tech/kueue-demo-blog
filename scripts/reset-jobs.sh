#!/usr/bin/env bash
# wipe jobs, keep the queues (used between acts)
set -uo pipefail
kubectl delete jobs --all -n research --wait=false >/dev/null 2>&1
kubectl delete jobs --all -n production --wait=false >/dev/null 2>&1
for n in $(kubectl get nodes -o name); do kubectl uncordon "$n" >/dev/null; done
while [ -n "$(kubectl get pods -n research -o name 2>/dev/null)$(kubectl get pods -n production -o name 2>/dev/null)" ]; do sleep 1; done
echo "jobs cleared, queues kept."
