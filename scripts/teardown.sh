#!/usr/bin/env bash
# nuke the cluster
set -euo pipefail
k3d cluster delete ai-cluster
