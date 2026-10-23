#!/usr/bin/env python3
"""live view of gpu nodes, clusterqueues and workloads, refreshes every 2s.

just shells out to kubectl so it still works before any queues exist (act 1).
"""
import json
import subprocess
import sys
import time

TEAM_NS = ("research", "production")
GPU = "nvidia.com/gpu"

R, B, DIM = "\033[0m", "\033[1m", "\033[2m"
RED, GRN, YEL, CYN, MAG = "\033[31m", "\033[32m", "\033[33m", "\033[36m", "\033[35m"
TEAM_COLOR = {"research": CYN, "production": MAG}


def kget(*args):
    try:
        out = subprocess.run(["kubectl", "get", *args, "-o", "json"],
                             capture_output=True, text=True, timeout=10)
        return json.loads(out.stdout)["items"] if out.returncode == 0 else []
    except Exception:
        return []


def cond(obj, ctype):
    for c in obj.get("status", {}).get("conditions", []) or []:
        if c["type"] == ctype:
            return c
    return None


def gpus(pod):
    total = 0
    for c in pod["spec"]["containers"]:
        total += int(c.get("resources", {}).get("limits", {}).get(GPU, 0))
    return total


def nodes_section(nodes, pods):
    lines = [f"{B}GPU NODES{R}"]
    for n in sorted(nodes, key=lambda n: n["metadata"]["name"]):
        cap = int(n["status"].get("allocatable", {}).get(GPU, 0))
        if not cap:
            continue
        name = n["metadata"]["name"].replace("k3d-ai-cluster-", "")
        cells = []
        for p in pods:
            if p["spec"].get("nodeName") == n["metadata"]["name"] and \
                    p["status"].get("phase") in ("Running", "Pending"):
                cells += [p["metadata"]["namespace"]] * gpus(p)
        bar = "".join(f"{TEAM_COLOR.get(ns, YEL)}■{R}" for ns in cells[:cap])
        bar += f"{DIM}□{R}" * (cap - len(cells[:cap]))
        state = f"  {RED}{B}CORDONED{R}" if n["spec"].get("unschedulable") else ""
        lines.append(f"  {name:<9} {bar}  {len(cells)}/{cap}{state}")
    pending = [p for p in pods if p["status"].get("phase") == "Pending" and not p["spec"].get("nodeName")]
    if pending:
        lines.append(f"  {YEL}{len(pending)} pod(s) Pending, holding nothing, waiting for a GPU{R}")
    lines.append(f"  {CYN}■ research{R}  {MAG}■ production{R}  {DIM}□ free{R}")
    return lines


def cq_section(cqs):
    if not cqs:
        return [f"{B}CLUSTERQUEUES{R}", f"  {DIM}none. It's a free-for-all{R}"]
    lines = [f"{B}CLUSTERQUEUES{R}",
             f"  {DIM}{'NAME':<11} {'COHORT':<12} {'GPU USED/QUOTA':<15} {'BORROWED':<9} {'ADMITTED':<9} PENDING{R}"]
    for cq in sorted(cqs, key=lambda c: c["metadata"]["name"]):
        name = cq["metadata"]["name"]
        quota = 0
        for rg in cq["spec"].get("resourceGroups", []):
            for f in rg["flavors"]:
                for r in f["resources"]:
                    if r["name"] == GPU:
                        quota += int(r["nominalQuota"])
        used = borrowed = 0
        for f in cq.get("status", {}).get("flavorsReservation", []) or []:
            for r in f["resources"]:
                if r["name"] == GPU:
                    used += int(r.get("total", 0))
                    borrowed += int(r.get("borrowed", 0))
        st = cq.get("status", {})
        color = TEAM_COLOR.get(name, "")
        b = f"{borrowed:<9}"
        if borrowed:
            b = f"{YEL}{b}{R}"
        lines.append(f"  {color}{name:<11}{R} {cq['spec'].get('cohortName') or '-':<12} "
                     f"{f'{used} / {quota}':<15} {b} "
                     f"{st.get('admittedWorkloads', 0):<9} {st.get('pendingWorkloads', 0)}")
    return lines


def wl_section(wls):
    if not wls:
        return []
    lines = [f"{B}WORKLOADS{R}",
             f"  {DIM}{'TEAM':<11} {'JOB':<22} {'PRIO':<7} {'GPUS':<5} STATE{R}"]
    for wl in sorted(wls, key=lambda w: (w["metadata"]["namespace"], w["metadata"]["creationTimestamp"])):
        ns = wl["metadata"]["namespace"]
        job = next((o["name"] for o in wl["metadata"].get("ownerReferences", [])), wl["metadata"]["name"])
        prio = (wl["spec"].get("priorityClassRef") or {}).get("name", "-")
        g = 0
        for ps in wl["spec"].get("podSets", []):
            for c in ps["template"]["spec"]["containers"]:
                g += int(c.get("resources", {}).get("limits", {}).get(GPU, 0)) * ps.get("count", 1)
        if cond(wl, "Finished") and cond(wl, "Finished")["status"] == "True":
            state = f"{DIM}finished{R}"
        elif cond(wl, "Admitted") and cond(wl, "Admitted")["status"] == "True":
            state = f"{GRN}● admitted{R}"
        else:
            ev = cond(wl, "Evicted")
            pre = cond(wl, "Preempted")
            if pre and pre["status"] == "True":
                why = {"InCohortReclamation": "GPUs reclaimed by owner",
                       "InClusterQueue": "preempted by higher priority"}.get(pre["reason"], "preempted")
                state = f"{RED}⟲ {why}, requeued{R}"
            elif ev and ev["status"] == "True" and ev["reason"] == "PodsReadyTimeout":
                state = f"{RED}⟲ pods never all started, requeued{R}"
            elif wl.get("status", {}).get("requeueState"):
                state = f"{YEL}... waiting (requeue #{wl['status']['requeueState'].get('count', 1)}){R}"
            else:
                state = f"{YEL}... queued, no pods created{R}"
        color = TEAM_COLOR.get(ns, "")
        lines.append(f"  {color}{ns:<11}{R} {job:<22} {prio:<7} {g:<5} {state}")
    return lines


def render():
    nodes = kget("nodes")
    pods = [p for ns in TEAM_NS for p in kget("pods", "-n", ns)]
    cqs = kget("clusterqueues.kueue.x-k8s.io")
    wls = [w for ns in TEAM_NS for w in kget("workloads.kueue.x-k8s.io", "-n", ns)]
    out = nodes_section(nodes, pods) + [""] + cq_section(cqs) + [""] + wl_section(wls)
    return "\n".join(out)


if __name__ == "__main__":
    once = "--once" in sys.argv
    while True:
        frame = render()
        sys.stdout.write("\033[H\033[2J" + frame + "\n")
        sys.stdout.flush()
        if once:
            break
        time.sleep(2)
