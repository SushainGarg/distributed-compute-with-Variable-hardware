#!/usr/bin/env bash
set -euo pipefail

group=${1:?usage: set-ray-workers.sh <worker-group> <replicas>}
replicas=${2:?usage: set-ray-workers.sh <worker-group> <replicas>}
ns=${NS:-alpa}
cluster=${CLUSTER:-dynamic-gpu-fleet}

idx=$(kubectl -n "$ns" get raycluster "$cluster" -o jsonpath='{range .spec.workerGroupSpecs[*]}{.groupName}{"\n"}{end}' | grep -nx "$group" | cut -d: -f1 || true)
[ -n "$idx" ] || { echo "no worker group '$group' in $cluster" >&2; exit 1; }
idx=$((idx - 1))

mapfile -t pods < <(kubectl -n "$ns" get pods -l "ray.io/cluster=$cluster,ray.io/group=$group" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
drop=$(( ${#pods[@]} - replicas ))

if [ "$drop" -gt 0 ]; then
  names=$(printf '"%s",' "${pods[@]:0:$drop}")
  patch="[{\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/$idx/replicas\",\"value\":$replicas},{\"op\":\"add\",\"path\":\"/spec/workerGroupSpecs/$idx/scaleStrategy\",\"value\":{\"workersToDelete\":[${names%,}]}}]"
  echo "removing ${pods[*]:0:$drop}"
else
  patch="[{\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/$idx/replicas\",\"value\":$replicas}]"
fi
kubectl -n "$ns" patch raycluster "$cluster" --type json -p "$patch"
kubectl -n "$ns" get pods -l "ray.io/cluster=$cluster,ray.io/group=$group" -o wide
