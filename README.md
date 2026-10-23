# kueue-demo-blog

Fighting over GPUs on a shared Kubernetes cluster, and how [Kueue](https://kueue.sigs.k8s.io) stops the fight. Runs on a laptop with k3d and fake GPUs, no cloud bill.

```
[Job + queue label] → [LocalQueue] → [ClusterQueue quota] → admitted → [kube-scheduler] → [GPU node]
```

---

## What you need

- Docker Desktop (I gave it 10 CPUs / 8 GB, less is fine)
- `k3d`, `kubectl`, `helm`, `tmux`, `python3`

```bash
brew install k3d kubectl helm tmux
```

---

## Setup

```bash
scripts/setup.sh
```

Takes ~3 minutes and needs internet once. It:
- Creates a k3d cluster `ai-cluster` — 1 server, 2 agents labelled `accelerator=nvidia-a100`
- Pulls `busybox:1.37` inside every node so nothing downloads mid-demo
- Patches each agent's node status with `nvidia.com/gpu: 4` (8 fake GPUs total)
- Installs Kueue **v0.20.2** + KueueViz with Helm (`manifests/kueue-values.yaml`)

---

## Running the demo

```bash
scripts/stage.sh        # tmux: demo on the left, live status on the right
scripts/demo.sh         # or just the demo, from act 1
scripts/demo.sh 5       # replay acts 1-4 quietly, start at act 5
```

Every command is printed first and runs when you hit **Enter**.

| Act | What happens |
|---|---|
| 1 | No Kueue. Research grabs 6 GPUs, production's 4-worker job half-starts |
| 2 | Queues + quotas. Extra work waits suspended with zero pods |
| 3 | Cohort. Research borrows production's idle GPUs |
| 4 | Production comes back and reclaims them |
| 5 | An `urgent` job preempts `batch` work, which comes back on its own later |
| 6 | A node dies mid-job, `waitForPodsReady` evicts the half-started job and requeues it |
| 7 | Queue positions from the visibility API + KueueViz |

---

## Other scripts

| Script | Does |
|---|---|
| `scripts/status.py` | Live view of GPUs per node, queue usage, workload states |
| `scripts/kueueviz.sh` | KueueViz at http://localhost:8080 |
| `scripts/queue-positions.sh <cq>` | Pending jobs and their position |
| `scripts/reset.sh` | Back to before act 1 (Kueue stays) |
| `scripts/reset-jobs.sh` | Delete jobs, keep queues |
| `scripts/teardown.sh` | Delete the cluster |

---

## Gotchas

- **`k3d image import` fails** on Docker Desktop with the containerd image store. `setup.sh` pulls inside each node with `crictl` instead.
- **KueueViz chart defaults to `pullPolicy: Always`** — fine until you're on conference wifi. The values file switches it to `IfNotPresent`.
- **The fake GPUs live in node status.** If a node restarts and they disappear, rerun `scripts/setup.sh`.
- `waitForPodsReady` timeout is **45s** so it fits in a talk. Use something like 10m for real clusters.
