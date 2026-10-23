#!/usr/bin/env bash
# "where is my job?" - pending list from kueue's visibility api
# usage: scripts/queue-positions.sh research
kubectl get --raw "/apis/visibility.kueue.x-k8s.io/v1beta2/clusterqueues/${1:?clusterqueue}/pendingworkloads" |
python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
if not items:
    print("  (nothing pending)")
for w in items:
    job = (w["metadata"].get("ownerReferences") or [{"name": w["metadata"]["name"]}])[0]["name"]
    pos, prio = w["positionInClusterQueue"], w.get("priority", 0)
    print(f"  #{pos + 1}  {job:<22} priority={prio}")
'
