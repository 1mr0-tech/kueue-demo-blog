#!/usr/bin/env bash
# back to the state before act 1: no jobs, no queues, nodes uncordoned.
# kueue stays installed
set -uo pipefail
cd "$(dirname "$0")/.."

kubectl delete jobs --all -n research --wait=false >/dev/null 2>&1
kubectl delete jobs --all -n production --wait=false >/dev/null 2>&1
kubectl delete localqueues.kueue.x-k8s.io --all -n research >/dev/null 2>&1
kubectl delete localqueues.kueue.x-k8s.io --all -n production >/dev/null 2>&1
kubectl delete clusterqueues.kueue.x-k8s.io --all >/dev/null 2>&1
kubectl delete resourceflavors.kueue.x-k8s.io --all >/dev/null 2>&1
kubectl delete workloadpriorityclasses.kueue.x-k8s.io --all >/dev/null 2>&1
for n in $(kubectl get nodes -o name); do kubectl uncordon "$n" >/dev/null; done
kubectl delete events --all -n research >/dev/null 2>&1
kubectl delete events --all -n production >/dev/null 2>&1

printf 'waiting for pods to go away'
while [ -n "$(kubectl get pods -n research -o name 2>/dev/null)$(kubectl get pods -n production -o name 2>/dev/null)" ]; do
  printf '.'; sleep 1
done
echo " clean."
