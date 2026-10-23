#!/usr/bin/env bash
# builds the whole thing: k3d cluster, fake gpus, kueue + kueueviz
# needs internet once, after that the demo works offline
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=ai-cluster
KUEUE_VERSION=${KUEUE_VERSION:-0.20.2}
GPUS_PER_NODE=${GPUS_PER_NODE:-4}
JOB_IMAGE=busybox:1.37

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if k3d cluster list -o json | grep -q "\"name\":\"$CLUSTER\""; then
  say "Cluster $CLUSTER already exists (run scripts/teardown.sh to rebuild)"
else
  say "Creating k3d cluster: 1 control plane + 2 'GPU' nodes"
  k3d cluster create --config cluster/k3d-config.yaml
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null

say "Preloading $JOB_IMAGE into the nodes (no image pulls on stage)"
# k3d image import kept failing on docker desktop's containerd image store, so pull inside each node
for node in $(k3d node list -o json | python3 -c 'import json,sys; print(" ".join(n["name"] for n in json.load(sys.stdin) if n["role"] in ("server","agent")))'); do
  docker exec "$node" crictl pull "$JOB_IMAGE" >/dev/null && echo "  $node: ok"
done

say "Advertising $GPUS_PER_NODE fake nvidia.com/gpu per worker node"
# no device plugin here, we just patch node status with an extended resource.
# scheduler and kueue only count the number so this behaves like real gpus
for node in $(kubectl get nodes -l accelerator=nvidia-a100 -o name); do
  kubectl patch "$node" --subresource=status --type=json -p "[
    {\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"$GPUS_PER_NODE\"},
    {\"op\":\"add\",\"path\":\"/status/allocatable/nvidia.com~1gpu\",\"value\":\"$GPUS_PER_NODE\"}]" >/dev/null
  echo "  $node: $GPUS_PER_NODE GPUs"
done

say "Installing Kueue v$KUEUE_VERSION (with KueueViz)"
helm upgrade --install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --version "$KUEUE_VERSION" \
  --namespace kueue-system --create-namespace \
  --values manifests/kueue-values.yaml \
  --wait --timeout 5m

say "Waiting for the Kueue webhook to answer"
until kubectl apply --dry-run=server -f manifests/queues/10-flavor.yaml >/dev/null 2>&1; do sleep 2; done

say "Pointing the KueueViz frontend at a local port-forward"
kubectl -n kueue-system patch configmap kueue-kueueviz-frontend-env --type=merge -p '{"data":{"env.js":"window.env = {\n  VITE_WEBSOCKET_URL: \"ws://localhost:8081\",\n  REACT_APP_WEBSOCKET_URL: \"ws://localhost:8081\"\n};\n"}}'
kubectl -n kueue-system rollout restart deployment/kueue-kueueviz-frontend >/dev/null
kubectl -n kueue-system rollout status deployment/kueue-kueueviz-frontend --timeout=2m

say "Creating namespaces (queues are created live in Act 2)"
kubectl apply -f manifests/queues/00-namespaces.yaml

say "Ready. Next: scripts/stage.sh to open the demo layout"
