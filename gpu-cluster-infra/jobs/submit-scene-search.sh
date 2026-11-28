#!/usr/bin/env bash
set -euo pipefail

usage="usage: IMAGE=590183833763.dkr.ecr.eu-west-2.amazonaws.com/scene_search_evaluation/experiments:<tag> [GPU_TIER=high_ada] [MEMORY=64Gi] [ARTIFACTS=/mnt/data/scene_search/artifacts] [DATASETS=/mnt/data/scene_search/datasets] $0 <job-name> <workers> <script.py> -- <overrides>"
: "${IMAGE:?$usage}"
JOB_NAME=${1:?$usage}
WORKERS=${2:?$usage}
SCRIPT=${3:?$usage}
shift 3
[ "${1:-}" = "--" ] && shift
export IMAGE JOB_NAME WORKERS SCRIPT
export ARGS="$*"
export GPU_TIER=${GPU_TIER:-high_ada}
export MEMORY=${MEMORY:-64Gi}
export ARTIFACTS=${ARTIFACTS:-/mnt/data/scene_search/artifacts}
export DATASETS=${DATASETS:-/mnt/data/scene_search/datasets}

kubectl -n alpa delete job "ss-$JOB_NAME" --ignore-not-found
envsubst '${IMAGE} ${JOB_NAME} ${WORKERS} ${SCRIPT} ${ARGS} ${GPU_TIER} ${MEMORY} ${ARTIFACTS} ${DATASETS}' < "$(dirname "$0")/scene-search-job.yaml" | kubectl apply -f -
echo "follow:  kubectl -n alpa get pods -l job=ss-$JOB_NAME -o wide -w"
echo "logs:    kubectl -n alpa logs -l job=ss-$JOB_NAME --prefix --tail=20"
echo "status:  kubectl -n alpa get job ss-$JOB_NAME"
