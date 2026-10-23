#!/usr/bin/env bash
# kueueviz on http://localhost:8080, ctrl-c to stop
set -euo pipefail
kubectl -n kueue-system port-forward svc/kueue-kueueviz-backend 8081:8080 >/dev/null &
BACK=$!
trap 'kill $BACK 2>/dev/null' EXIT
sleep 1
(sleep 2; open http://localhost:8080) &
echo "KueueViz on http://localhost:8080"
kubectl -n kueue-system port-forward svc/kueue-kueueviz-frontend 8080:8080 >/dev/null
