# distributed-compute-with-Variable-hardware Architecture

This repository maintains the production architecture for a multi-node, uneven GPU cluster designed to run plug-and-play inference workloads and distributed simulation applications (e.g., AlpaSim) over a standard network subnet.

---

## 1. System Topology Map

```text
+-----------------------------------------------------------------------------------------+
|                                APPLICATION LAYER (Ray)                                  |
|                                                                                         |
|    +-----------------------+   +---------------------------------------------------+    |
|    |   vLLM / Ray Serve    |   |                ALPASIM PIPELINE                   |    |
|    | (Dynamic Model Router)|   | (Co-located via Local Pod/Actor Node Affinity)    |    |
|    +-----------------------+   +---------------------------------------------------+    |
|                |                                         |                              |
|                +-------------------+---------------------+                              |
|                                    | (Plasma Shared Memory / gRPC)                      |
+------------------------------------v----------------------------------------------------+
|                        ORCHESTRATION LAYER (KubeRay Operator)                           |
|                                                                                         |
|      [Ray Head Pod]                  [Ray Worker Pods]                                  |
|     (No GPU assigned)         (Auto-scaled to physical capacity)                        |
+------------------------------------v----------------------------------------------------+
|                         COMPUTE CONTAINER LAYER (K3s + NVDP)                            |
|                                                                                         |
|  +---------------------------+ +---------------------------+ +------------------------+  |
|  |       Control Plane       | |        Worker Node        | |       Worker Node      |  |
|  |  (K3s Server + Registry)  | |        (K3s Agent)        | |       (K3s Agent)      |  |
|  +---------------------------+ +---------------------------+ +------------------------+  |
+------------------------------------v----------------------------------------------------+
|                          HARDWARE & INTERCONNECT LAYER                                  |
|                                                                                         |
|  +---------------------------+ +---------------------------+ +------------------------+  |
|  |          NODE 1           | |          NODE 2           | |         NODE 3         |  |
|  |  High CPU / 4x RTX 4090   | |  Mid CPU / 2x RTX 3090    | |  Low CPU / 1x RTX 2080 |  |
|  +---------------------------+ +---------------------------+ +------------------------+  |
|                |                             |                             |            |
|                +-----------------------------+-----------------------------+            |
|                                              |                                          |
|                              [ Standard LAN Ethernet Subnet ]                           |
+-----------------------------------------------------------------------------------------+
|                            CENTRALIZED STORAGE SUB-SYSTEM                               |
|                                                                                         |
|                     [ Shared Network Volume (NFS / MinIO S3 Bucket) ]                   |
|                     └── Models / Dataset Cache / AlpaSim Telemetry Logs                 |
+-----------------------------------------------------------------------------------------+
```

---

## 2. Structural Component Matrix

| Layer | Component Selected | Architectural Role / Guardrail |
| :--- | :--- | :--- |
| **Physical Interconnect** | Standard LAN Subnet | **Data Parallel/gRPC Only.** Sharded tensor parallelism (FSDP/Megatron) across nodes is strictly banned due to network limits. |
| **Storage Sub-System** | S3-Compatible / NFS | **Decoupled Persistence.** Centralized hub for plug-and-play weights and simulation logs; mounted to all K8s workers. |
| **Infrastructure** | K3s (Lightweight K8s) | **Resource Pooling.** Creates a unified fabric across heterogeneous hardware; handles self-healing container lifetimes. |
| **Device Management** | NVIDIA Device Plugin | **Resource Profiling.** Discovers and exposes distinct host GPU capacities (`nvidia.com/gpu`) up to the K8s API. |
| **Cluster Bridge** | KubeRay Operator | **Dynamic Provisioning.** Automates the translation of Python ML scaling into K8s Head/Worker pod deployments. |
| **Inference Engine** | Ray Serve | **Dynamic Ingress Graph.** Abstracts the GPU matrix into a hot-swappable, lazy-loading multi-application web API. |
| **Simulation Engine** | AlpaSim Framework | **Modular Microservices.** Uses Node Affinity constraints to force heavy rendering and VLA policies to sit on identical physical PCIe lanes. |

---

## 3. Workload Execution Frameworks

### Dynamic Inference Loop (`RayService`)
```yaml
Model Request -> [API Gateway Router] -> [Check Active Memory] ──(If Missing)──> [Pull Weights from S3/NFS]
                                |                                                        |
                                v                                                        v
                     [Route to Active Worker Pod] <─────────────────────────── [Bind to Open GPU Target]

## Modular Simulation Loop (AlpaSim + Ray Tasks)

[Cluster Scheduler]
        |
        ├───> (Resource Demand: num_gpus=0, num_cpus=8) ──> [Low-Tier / High-CPU Worker Node] ──> Physics & Traffic Engine
        |
        └───> (Resource Demand: num_gpus=1+, Local Host) ─> [High-Tier GPU Worker Node] ───────> Neural Renderer & VLA Policy
```

```text
gpu-cluster-infra/
├── .gitignore
├── README.md           
├── scripts/
│   ├── install-nvidia.sh   <-- Drivers & Container Toolkit
│   └── setup-nfs.sh        <-- Exports the local Storage Drive
└── kubernetes/
    ├── base/               <-- Core cluster configuration
    │   ├── nfs-pv.yaml     <-- The Storage YAML
    │   └── nfs-pvc.yaml    <-- The Claim YAML
    ├── kuberay/            <-- Ray Operator deployment manifests
    └── apps/               <-- workloads
        ├── inference/      <-- RayService YAMLs (vLLM, custom APIs)
        └── alpasim/        <-- RayJob or Pod configurations
```