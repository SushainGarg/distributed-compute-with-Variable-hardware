# Scaling the vLLM model servers

Each model is one Deployment in namespace `alpa` behind one NodePort Service. More replicas of a Deployment land on any free GPU of its `gpu-tier`, and the same NodePort load-balances over all ready replicas, so clients keep the same URL.

| Model | Deployment / Service | Tier | NodePort |
|---|---|---|---|
| Qwen3-VL-8B | `vllm-qwen3-vl-8b` | `mid` | 30801 |
| Nemotron 3 Nano 30B-A3B | `vllm-nemotron3-nano` | `high_ada` | 30802 |
| Qwen3-VL-30B-A3B | `vllm-qwen3-vl-30b-a3b` | `high_ada` | 30803 |
| Gemma 4 31B | `vllm-gemma-4-31b` | `high_ada` | 30804 |

Nothing autoscales: the split of GPUs between the RayCluster workers and the model servers is set by hand with the steps below.

## 1. Find free GPUs

```bash
kubectl get nodes -L gpu-tier
kubectl describe nodes | grep -E '^Name:|nvidia.com/gpu'          # capacity vs allocated per node
kubectl -n alpa get pods -o wide | grep -E 'vllm|ray'             # who holds the GPUs
```

## 2. Free GPUs held by Ray workers

```bash
vllm/set-ray-workers.sh max-ultra-1gpu-pool 0          # <worker group> <replicas>; removes the named pods, not random ones
```

Worker groups: `ultra-4gpu-pool`, `ultra-2gpu-pool`, `mixed-low-3gpu-pool`, `max-ultra-1gpu-pool`, `mid-1gpu-pool`.

## 3. Scale the model servers

```bash
kubectl -n alpa scale deploy/vllm-qwen3-vl-30b-a3b deploy/vllm-gemma-4-31b --replicas=2
kubectl -n alpa get pods -l app=vllm-qwen3-vl-30b-a3b -o wide -w    # Ready after the model load (10-40 min, startup probe allows it)
kubectl -n alpa get endpoints vllm-qwen3-vl-30b-a3b                # one IP per ready replica
```

Replicas of one model are spread over nodes (`topologySpreadConstraints`, `ScheduleAnyway`), so two 30B replicas do not share one node's RAM unless no other node has a free GPU. A replica that stays `Pending` means no free GPU in its tier: free more in step 2.

## 4. Check the load is spread

```bash
for p in $(kubectl -n alpa get pods -l app=vllm-qwen3-vl-30b-a3b -o name); do
  echo "$p: $(kubectl -n alpa exec $p -- python3 -c "import urllib.request as u; print(u.urlopen('http://localhost:8000/metrics').read().decode())" | grep -E '^vllm:num_requests_(running|waiting)' | tr '\n' ' ')"
done
```

The Service balances per connection; clients with many concurrent requests open several connections, so replicas get a roughly even share. On the client side run several annotation ranks (`scripts/annotate_ranks.sh` in the scene-search repo) with `batch_size` 16-32 so each replica sees enough requests in flight.

## 5. Scale back

```bash
kubectl -n alpa scale deploy/vllm-qwen3-vl-30b-a3b deploy/vllm-gemma-4-31b --replicas=1
vllm/set-ray-workers.sh max-ultra-1gpu-pool 2          # restore the Ray workers
```

`kubectl scale` does not restart the running replica. Re-applying a changed manifest does (`strategy: Recreate`): the model is down for one load time.
