# Scene-search jobs on the cluster

Large embedders (multimodal-LLM embedders, 2–8B) are too slow for one workstation. These files run the scene-search repo's `ingest.py` / `ingest_clips.py` (or any of its scripts) as a Kubernetes **Indexed Job**: N pods, one GPU each; pod i gets `RANK=i`, `WORLD_SIZE=N`, embeds every N-th item, and writes into the shared embedding store. The npy store names shards by time and process id, so pods never overwrite each other. Small models (CLIP, SigLIP, PE-Core, X-CLIP, DINOv3, Cosmos-Embed1) stay on the workstation with the GPU planner.

| File | Purpose |
|---|---|
| `scene-search-job.yaml` | Indexed Job template (filled by `envsubst`) |
| `submit-scene-search.sh` | Fills the template and applies it |

## 1. Shared storage layout

Everything lives on the NFS volume (`cluster-storage-pvc` → `10.213.14.170:/mnt/hdd2/cluster_dat`, mounted at `/mnt/data` in pods):

```
/mnt/hdd2/cluster_dat/                       (= /mnt/data in pods)
├── models/<folder>                          weights, one folder per model (names below)
└── scene_search/
    ├── datasets/{nuscenes,bdd100k,acdc,mapillary}/...   same layout as $DATA
    └── artifacts/                           = $ART: datasets/<name>/metadata.csv.gz, embeddings/, similarity/, hydra/
```

Use this artifacts folder as `ART` on the workstation too, so the embeddings written by pods are the ones `run.py` reads. Copy, on the NFS server:

```bash
D=/mnt/hdd2/cluster_dat
mkdir -p $D/scene_search/datasets $D/scene_search/artifacts $D/models
rsync -a --info=progress2 /mnt/hdd1/datasets/scene_search_datasets/{acdc,bdd100k} $D/scene_search/datasets/
rsync -a --info=progress2 --include='*/' --include='samples/CAM_FRONT/**' --include='sweeps/CAM_FRONT/**' --include='v1.0-*/**' --exclude='*' /mnt/hdd1/datasets/scene_search_datasets/nuscenes/ $D/scene_search/datasets/nuscenes/
rsync -a --info=progress2 <old ART>/ $D/scene_search/artifacts/        # metadata, existing embeddings and results
```

## 2. Model folders

Pods resolve weights as `site.models_root=/mnt/data/models` + the folder names of the scene-search site config. Copy what you will run on the cluster:

```bash
for m in Qwen3-VL-Embedding-2B Qwen3-VL-Embedding-8B gme-Qwen2-VL-2B-Instruct jina-embeddings-v4 jina-embeddings-v5-omni-small \
         Ovis-VL-Embedding-2B embeddinggemma-2 GVE-3B GVE-7B Qwen3-Embedding-0.6B Qwen3-Embedding-4B Qwen3-Embedding-8B \
         Cosmos-Reason2-8B Cosmos-Reason2-32B GLM-4.6V-Flash LLaVA-OneVision-2-8B-Instruct Qwen3.5-35B-A3B Qwen3.5-27B Qwen3.8-27B; do
  rsync -a /mnt/hdd1/datasets/$m $D/models/
done
rsync -a /mnt/hdd1/datasets/allenai/Molmo2-8B $D/models/            # served from /mnt/data/models/Molmo2-8B
```

The full GLM-4.6V (106B; ~210 GB BF16, ~110 GB FP8) does not fit any node: skip it.

## 3. Container image (once per code change)

Built from the scene-search repo (`embedding_analysis/`), pushed to the registry the nodes pull from (`dockerhub-cred`):

```bash
cd embedding_analysis && uv lock                       # after any pyproject change
docker build -f docker/Dockerfile -t <registry>/scene-search:<tag> .
docker build -f docker/Dockerfile --build-arg TRANSFORMERS=">=5.12.1" -t <registry>/scene-search:<tag>-t5 .   # Ovis / EmbeddingGemma 2
docker push <registry>/scene-search:<tag> && docker push <registry>/scene-search:<tag>-t5
```

## 4. Free GPUs and submit

```bash
vllm/set-ray-workers.sh max-ultra-1gpu-pool 0                          # free 48 GB Ada GPUs (see vllm/SCALING.md)
export IMAGE=<registry>/scene-search:<tag>
jobs/submit-scene-search.sh qwen8b-bdd 4 ingest.py -- source=dataset dataset=bdd100k "'ingest_models=[qwen3_vl_embedding_8b]'"
jobs/submit-scene-search.sh gve7b-nus-clips 2 ingest_clips.py -- dataset=nuscenes "'ingest_models=[gve_7b]'"
IMAGE=<registry>/scene-search:<tag>-t5 jobs/submit-scene-search.sh ovis-bdd 2 ingest.py -- source=dataset dataset=bdd100k "'ingest_models=[ovis_vl_embedding_2b]'"
GPU_TIER=mid MEMORY=40Gi jobs/submit-scene-search.sh jina5-acdc 2 ingest.py -- source=dataset dataset=acdc "'ingest_models=[jina_v5_omni_small]'"
```

- Arguments after `--` are passed to the script; quote list overrides as shown (they end up inside `bash -c`).
- Always pass `source=dataset` to `ingest.py` (the site default is S3).
- The template adds `site=jlr site.models_root=/mnt/data/models site.artifacts_root=… site.datasets_root=… site.half_dtype=bfloat16 store=npy` and a Hydra folder per pod under `artifacts/hydra/k8s/<job>/rank<i>`.
- `GPU_TIER` picks the node tier (`high_ada` 48 GB default, `mid` 24 GB); `MEMORY` is the container RAM limit (default 64Gi).
- One model per job for big models (each pod loads every model it is given).
- A pod that fails is retried twice (`backoffLimitPerIndex`). Re-submitting the same job name deletes and restarts it; already-embedded items are written again (the newest vector per id wins), so for a partial rerun prefer finishing with the same job.

## 5. Watch and finish

```bash
kubectl -n alpa get pods -l job=ss-qwen8b-bdd -o wide -w
kubectl -n alpa logs -l job=ss-qwen8b-bdd --prefix --tail=20
kubectl -n alpa get job ss-qwen8b-bdd                                  # COMPLETIONS 4/4 when done
vllm/set-ray-workers.sh max-ultra-1gpu-pool 4                          # give the GPUs back
```

Then run the benchmark on the workstation with `ART` pointing at `/mnt/hdd2/cluster_dat/scene_search/artifacts` (or `run.py` itself as a job: `jobs/submit-scene-search.sh run-bdd 1 run.py -- -m dataset=bdd100k model=...`; it needs little GPU).

## vLLM servers for the new captioners

Manifests in `vllm/`, same pattern as the existing ones (weights from `/mnt/data/models/<folder>`, NodePort per model):

| Manifest | Model | Tier | Port |
|---|---|---|---|
| `cosmos-reason2-8b.yaml` | Cosmos-Reason2-8B | mid (24 GB) | 30805 |
| `cosmos-reason2-32b.yaml` | Cosmos-Reason2-32B, FP8 | high_ada (48 GB) | 30806 |
| `molmo2-8b.yaml` | Molmo2-8B | mid | 30807 |
| `glm-4-6v-flash.yaml` | GLM-4.6V-Flash (9B) | mid | 30808 |
| `llava-ov2-8b.yaml` | LLaVA-OneVision-2-8B (vLLM support unverified) | mid | 30810 |
| `qwen3-5-35b-a3b.yaml` | Qwen3.5-35B-A3B, FP8 | high_ada | 30811 |
| `qwen3-5-27b.yaml` | Qwen3.5-27B, FP8 | high_ada | 30812 |
| `qwen3-8-27b.yaml` | Qwen3.8-27B, FP8 | high_ada | 30813 |

`kubectl apply -f vllm/<file>.yaml`, then `python scripts/check_vllm_endpoints.py site=jlr site.vllm_host=<node IP> --backends <backend>` from the scene-search repo. Qwen3.5 / 3.8 need a vLLM build that supports them; if `v0.28.0` fails to load them, change `image:` in those three manifests to a newer `vllm/vllm-openai` tag.
