# Advice: identity, a no-cloud build plan, and Ray vs Slurm

## Context

The design in `cluster_design.md` / `implementation.md` assumed three things that aren't true today:

| Assumed | Actual (your answers) | Consequence |
|---|---|---|
| Entra ID / AD as the identity source | **No central directory**; local Linux accounts per machine | The planned OIDC-to-Entra and SSSD-to-AD design can't be built. Identity has to be created, not just connected |
| AWS available to the cluster (ECR, Secrets Manager, Roles Anywhere, ClearML on AWS), hybrid later | **Human AWS CLI access only: push/pull existing ECR repos, read secrets. You can't create IAM roles or trust anchors. No VPN/hybrid. Internet OK** | ECR can stay the image source of truth, but nodes have no AWS identity of their own. Machine credentials become a request to whoever owns IAM. EKS/MultiKueue stays deferred |
| Greenfield nodes | **Nodes in use ad hoc over SSH** | You need a migration plan, with no big-bang cutover, and UIDs to clean up |
| An existing NFS appliance for shared data | **No NFS today; mixed SSDs and HDDs spread across nodes that must stay put; 1 GbE network** | Shared storage has to be built by pooling the nodes' disks. Network speed is the main constraint |
| Mostly Python ML | **Mix of ML and MPI/HPC** | The Ray vs Slurm question is real, but it's a different question than it looks |

You'll do all the implementation yourself. This file is advice only: decisions, order, and what to check. No code or config is generated.

---

## 1. Keycloak vs what was planned

### The planned design no longer applies
The plan pointed the API server, Grafana, Argo CD and oauth2-proxy at Entra ID, and SSSD at AD. With no directory, you need two things you don't have:
1. **An OIDC provider** for everything web and `kubectl`.
2. **Consistent POSIX identities** (same username, UID and GID on every node) for SSH and, critically, for the shared filesystem (CephFS, §2). File ownership is stored as a UID, so the UID *is* the identity.

Keycloak solves (1). It does not solve (2) by itself, because it isn't a Linux account source for SSSD.

### Recommendation: Keycloak for OIDC, plus Ansible-managed POSIX accounts
- **Keycloak** is the single OIDC issuer for the API server (kubelogin), Argo CD, Grafana, Harbor, and oauth2-proxy (Ray dashboard, KueueViz, Hubble). Users and groups live in Keycloak for now.
- **POSIX accounts** come from a UID/GID registry file in Git, applied by Ansible: SSH keys only, no passwords, and groups matching the Keycloak group names. Usernames are identical in both places, so the job recorder, the `platform/user` label and the SSH user all line up.

**Why Keycloak rather than going straight to Entra (if the org offers it later), or a lighter tool:**
- **A stable issuer.** The API server's OIDC config and every app's client config point at Keycloak once. Later, if Entra ID or AD appears, you add it to Keycloak as an identity provider (brokering) or as LDAP user federation, and no client changes. That matters most for the API server, where changing the OIDC flags is a control-plane change.
- **It works with no upstream directory.** Dex needs a backing connector and has only static users otherwise, which is fine for a demo but not for operations. Authentik and Kanidm are viable, but Keycloak is the most widely run and documented option, and kubelogin, Argo CD, Grafana and Harbor all have well-trodden Keycloak guides.
- **It gives you policy you'd otherwise lack:** MFA (TOTP/WebAuthn), brute-force lockout, token lifetimes, group claims, and an audit log of logins.

**What it costs (be honest about these in the ADR):**
- It's a stateful service on the login path. If Keycloak is down, no one can get a *new* token for kubectl, Grafana or Argo CD.
- It needs HA: 2 replicas, PostgreSQL via CloudNativePG with WAL archiving, and its clustering cache configured. Keycloak releases often, so plan an upgrade every quarter or so and read the migration notes each time.
- It's another TLS endpoint every client must trust.

**How to keep it from hurting stability:**
- **SSH never depends on Keycloak.** Ansible-managed accounts mean you can log in to nodes even when the cluster and Keycloak are down. This is why I'm recommending this over FreeIPA or SSSD for now.
- **A break-glass kubeconfig:** the RKE2 admin client certificate, kept offline and encrypted. Test it quarterly.
- Run Keycloak in the cluster, on CNPG, with backups to Ceph RGW and dumps to the off-cluster backup box (§2).
- Use the API server's **structured authentication configuration** if your pinned Kubernetes version supports it (verify). It allows multiple issuers and reloads without restarting the API server, which makes adding Entra later, or rotating clients, painless.

**When to move up to FreeIPA (or AD later):** past roughly 30–50 users, when you need central passwords or sudo policy, or when onboarding through PRs becomes a chore. Then FreeIPA becomes the POSIX and LDAP source, and Keycloak federates it read-only. If you keep UIDs stable from day one, this is a migration, not a rebuild.

**Later option:** short-lived SSH certificates (for example step-ca with an OIDC provisioner pointing at Keycloak). Users get an SSH cert by logging in, and nodes trust the CA, so there are no per-user keys to distribute. Keep it in mind for later; don't build it first.

### Must-do cleanup because of the ad hoc SSH history
- **Audit UIDs on every node now.** Ad hoc local accounts almost certainly have different UIDs for the same person on different machines. Build the UID registry, then fix ownership as homes move to the shared `/home` (§2). This is the most likely source of "my files disappeared" incidents.
- **Pods and shared storage:** decide how pods get file ownership. Either pods run as the submitting user's UID, enforced by Kyverno from the registry so nobody can set someone else's `runAsUser`, or teams use shared GIDs with `fsGroup`. Without one of these, any user can read anyone's data from a pod.

---

## 2. Storage: pooling the disks, shared homes, clean nodes

### What changed
There is **no NFS server today**, the nodes are on **1 GbE**, and the **disks have to stay in the nodes** they're in. The design assumed an existing NFS appliance, so shared storage now has to be built from the disks spread across the nodes. That makes storage the first thing to get right. Shared homes and consistent accounts are what make the rest of the build easier.

### Split the disks by job: local and pooled
**Container and Kubernetes data must stay on local disks, not pooled storage.** containerd's overlay snapshots and kubelet's pod volumes don't work properly on network filesystems, and etcd needs low-latency local SSD. So "move the Docker/Kubernetes root off `/`" is right, but the target is a **dedicated local partition**, not the pool.

Per node, with LVM on the OS SSD, formatted XFS:

| Mount | Size (starting point) | Why separate |
|---|---|---|
| `/` | 50–64 GB | OS only; stays small and replaceable |
| `/var/log` | 10–20 GB | Runaway logs can't fill `/` |
| `/var/lib/rancher` (RKE2 + containerd images) | 150–250 GB, SSD | CUDA images are 10–20 GB each; image GC thresholds are set against this disk |
| `/var/lib/kubelet` (pod emptyDir, ephemeral storage) | 100 GB+, SSD | Pod scratch can't fill `/`; kubelet evicts on this disk's thresholds |
| `/var/lib/rancher/rke2/server/db` (etcd, **servers only**) | 20–50 GB, fastest SSD | etcd fsync latency; ideally its own physical SSD |
| `/scratch` (optional, spare local SSD) | What's left | Staging datasets next to the GPUs (see 1 GbE below) |
| `/local/admin` | Small | Break-glass admin homes that work even when the shared `/home` is down |

**Every other disk** (spare SSDs and all HDDs) goes into the pool as whole devices. Disks holding the OS never do.

While Docker is still used on ad hoc nodes, give `/var/lib/docker` its own LV too. It goes away once a node joins RKE2, which uses containerd.

### Pooling: Ceph, run outside Kubernetes
To pool mixed SSDs and HDDs across many nodes, keep data safe when a node dies, and serve a shared POSIX filesystem with per-directory quotas, **Ceph is the only mature option**. One system gives you:
- **CephFS:** shared `/home` with quotas, and project/dataset space. Replaces the NFS the design assumed.
- **RBD:** block volumes for Kubernetes PVCs where needed.
- **RGW (S3):** etcd snapshots, Velero, Loki, checkpoints. **Replaces Garage**, so you run one storage system, not two. ADR-0004 rejected Ceph as too heavy "unless block storage is needed later". The requirements have now changed, so supersede it.

The alternatives don't fit:
- **GlusterFS:** in maintenance mode upstream; don't start new.
- **MooseFS CE:** simpler, but the metadata master is a single point of failure in the free edition.
- **LizardFS:** stagnant.
- **BeeGFS:** built for fast scratch; no real replication.
- **mergerfs or LVM:** pool disks inside one machine only.

**Run it with `cephadm` on the hosts, not with Rook inside Kubernetes.** Homes are needed by SSH users even when Kubernetes is broken, and principle 2 says what restores the cluster lives outside it. Kubernetes consumes Ceph as an *external* cluster through ceph-csi.

**What Ceph costs (put it in the ADR):**
- It's the most complex component in this design, and you're one person. Learn it in the lab VMs first: Ceph runs fine on small virtual disks. Practise losing an OSD, a whole host, and a MON.
- **Memory:** each OSD wants ~4 GB by default (it can be lowered to ~2–3 GB). Add the MON, MGR and MDS daemons, and GPU nodes running OSDs lose RAM that jobs could use. Reserve it explicitly with systemd slices and kubelet `system-reserved`.
- **Pin a stable release** and upgrade with cephadm's orchestrated upgrade, one release at a time.

**Layout:**
- **Daemons:** 3 MONs and 2 MGRs on the CPU nodes, MON data on SSD (separate from etcd's disk if possible). 2 MDS (active + standby) for CephFS. One OSD per pooled disk, on every node that has spare disks.
- **Device classes:** Ceph tags OSDs `ssd` or `hdd`. Pools pick a class:

| Pool | Class | Protection | Holds |
|---|---|---|---|
| CephFS metadata | ssd | 3 replicas | Directory tree; latency matters most |
| `home` data | hdd (or ssd if enough) | 3 replicas | User homes: many small files, so no erasure coding |
| `projects` / datasets data | hdd | Erasure coding 4+2 if ≥ 6 hosts have HDDs, else 3 replicas | Bulk data |
| RBD | ssd | 3 replicas | The few PVCs that need block storage |
| RGW (S3) | hdd | 3 replicas or EC | Backups, logs, checkpoints |

- **Failure domain = host,** with `min_size 2`, so losing any one node loses no data and keeps it writable.

**Capacity, said plainly:** pooling with redundancy gives you *less* usable space than the raw total. Three replicas give about one-third of raw. EC 4+2 gives about two-thirds. Keep Ceph under ~75% full. As an example, 40 TB raw comes to about 10 TB usable at 3 replicas, or about 20 TB with EC for bulk data. Uneven disk sizes per host lower this further, because each host has to hold its share of copies. **Do the disk inventory and this sum first.** If it doesn't fit, decide what doesn't need 3 copies (scratch, re-downloadable datasets) rather than lowering replicas everywhere.

### Living with 1 GbE (the biggest risk in this design)
- **One node can read or write at most ~110 MB/s** from the pool, whatever the filesystem. Fine for homes and code. Too slow to feed GPUs from shared datasets.
- **Pattern for training:** stage datasets once into node-local `/scratch` (SSD), cache them there, and checkpoint back to the pool. The job templates should do this by default.
- **When a node dies, Ceph re-copies its data** over the same 1 GbE links that jobs and MPI use. That can take hours to days and slow everything. Throttle it: use the mClock "high client ops" profile and low backfill limits. Set `noout` before planned reboots, such as GPU driver updates, so a short maintenance doesn't trigger a rebuild.
- **If nodes have a second 1 GbE port,** give Ceph its own cluster network for replication on it. That's the cheapest relief.
- **A 10 GbE switch and NICs is the single most valuable hardware purchase** for this cluster. Ask for it now, and record it as a known limit in the ADR.

### Shared homes with quotas and alerts
- **One CephFS area just for homes** (its own data pool or subvolume group). This is the "dedicated partition" you asked for: a pool quota caps total home space, so homes can never eat project space.
- Mount it at **`/home` on every node,** including the still-ad-hoc ones, via a systemd mount that waits for the network.
- **Per-user quota:** a CephFS directory quota (`ceph.quota.max_bytes`, optionally `max_files`) on each `/home/<user>`, set from the same Git registry that holds UIDs. The kernel client enforces it with a short lag, so users can overshoot slightly before writes fail.
- **Alerts:** CephFS exposes each directory's recursive usage (`ceph.dir.rbytes`). A small exporter or a node-exporter textfile script on one node publishes usage versus quota per user. Warn at 80%, critical at 95%, plus pool-level and Ceph `nearfull` alerts. Route user alerts by email, using the addresses in Keycloak.
- **Self-service undelete:** CephFS scheduled snapshots on `/home` (for example hourly ×24, daily ×7, weekly ×4). Users restore from `.snap` themselves. These are **not backups**: they live in the same Ceph.
- **Migrating today's scattered homes:**
  1. Fix UIDs first, using the registry.
  2. Copy each user's old home from each machine into `/home/<user>/old-<hostname>/`, with ownership set to the new UID. Don't merge copies automatically.
  3. Let users tidy up within a deadline, while quotas are in "alert only" mode (set them high).
  4. Then turn real quotas on.
- **Pods and homes:** the same UID rule as before applies (Kyverno). Pods mount CephFS paths only as their own user.

### Backups with limited space
A Ceph cluster isn't a backup of itself: an operator mistake or a bug hits all copies. Since full off-cluster copies don't fit, **protect a small critical set off-cluster and accept snapshots for the rest:**
- **Off-cluster (backup box: one spare machine or even a large external disk, append-only):** etcd snapshots, Keycloak and job-record database dumps, the Git mirror, a Harbor DB dump, the SOPS key (sealed), and a Ceph config/keyring backup. This is tens of GB.
- **Homes:** bounded by quotas, so their total size is known. Back them up off-cluster if the box can take it; otherwise rely on snapshots and **tell users, in writing,** that homes have no off-cluster backup.
- **Datasets:** re-downloadable data isn't backed up. Say which ones.

---

## 3. Implementation plan: local only, stability and recovery first

### Principles (these drive the order)
1. **Git is the source of truth.** You should be able to rebuild the platform from Ansible plus Argo CD, then restore the stateful pieces from backup. Prove it with a rebuild drill.
2. **Anything needed to start or restore the cluster lives outside it:** Git, the registry, the object store holding etcd snapshots, the decryption key for secrets, SSH access, DNS and the time servers. Otherwise a broken cluster can't fix itself.
3. **Backups leave the failure domain.** Ceph's 3 copies survive a disk or node, but a deletion replicates instantly and all copies sit in one room. Keep the small critical set (§2) on a separate, append-only backup box, on a different power circuit if possible.
4. **An untested backup doesn't count.** Every phase ends with a drill, and restores are timed.
5. **Monitoring comes before workloads,** not in the last phase.
6. **Rehearse in a lab first.** Run 3–4 VMs on one workstation for Ansible roles, RKE2 installs, upgrades and the etcd restore. Only GPU-specific steps need a real node.

### How to use AWS with CLI-level access only

**Rule: personal AWS credentials never go on nodes or into the cluster.** Your CLI login is a human identity. Copying it onto shared nodes or into a Secret would give every job your access and tie the platform to your account.

That leaves one gap: something on-prem has to pull from ECR as a machine. Close it with **one machine credential in one place**, not on every node.

**Recommended: ECR stays the source of truth, with an on-prem Harbor mirror in front of it.**
- **Harbor** runs as a host service on a CPU node. Its proxy-cache project (or a pull-replication rule) uses ECR as the upstream endpoint. Harbor has an AWS ECR endpoint type; verify it in your pinned version.
- **Nodes pull only from Harbor.** There are no AWS credentials on nodes and no ecr-credential-provider for now. Spegel still shares layers between nodes.
- **More stable than the original plan.** Images already mirrored to Harbor survive an AWS or internet outage, even on a node that never pulled them. Spegel alone only covers images some node has already pulled.
- **Harbor also proxies the public registries** (quay.io, registry.k8s.io, docker.io, nvcr.io) for platform images. The Kyverno allowlist then becomes "Harbor only".
- **Internal images:** CI (or you, with your CLI access) pushes to the *existing* ECR repos, and Harbor picks them up. You can't create repos yourself, so agree a naming scheme that fits the repos you have (for example one repo per team with tags), or batch new-repo requests.

**The one request to the IAM owners (Phase 0, start it early, as lead times vary):**
**What the credential is for:** read-only access to the org's ECR, in one direction: ECR → Harbor → nodes. It never pushes, deletes or changes anything in ECR. Pushes to ECR stay with CI or a human.

The permissions depend on the Harbor mode:
- **Proxy cache** (an image is pulled the first time a node asks for it): `ecr:GetAuthorizationToken` (resource `*`), plus `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` and `ecr:BatchCheckLayerAvailability` on your repos.
- **Pull replication** (Harbor copies chosen repos and tags on a schedule, so they're on-prem before anyone asks): all of the above, plus `ecr:ListImages`, `ecr:DescribeImages` and `ecr:DescribeRepositories`, so Harbor can see which tags exist.

This is the same action set as AWS's managed `AmazonEC2ContainerRegistryReadOnly` policy, scoped to your repos. Use replication for images that must survive an outage, and the proxy cache for everything else.

1. **Preferred:** an IAM Roles Anywhere trust anchor and a role with the read-only policy above, for the mirror host's certificate. If Harbor's ECR adapter can't use Roles Anywhere credentials (it typically expects an access key), replace Harbor's ECR pull with a small sync job on the mirror host. That job uses the signing helper and copies tags into Harbor on a timer. You write it, so it's your call.
2. **Fallback:** a dedicated IAM user with that same read-only policy and an access key, stored with SOPS. Rotate it every 90 days, with a reminder and an alert.
3. **If ClearML artifacts live in S3:** in the same request, a machine identity with read/write on one bucket prefix per team (see "ClearML on-prem").
4. **Later, the same request again:** a read role for Secrets Manager (for ESO), and an S3 bucket with object lock for offsite backups.

| Planned | Now | When the machine identity exists |
|---|---|---|
| ECR via kubelet credential provider on every node | ECR → **Harbor mirror** (one credential) → nodes | Keep the mirror; it's the more stable shape anyway. Optionally add the node credential provider as a fallback |
| Secrets Manager + ESO | **SOPS + age** in Git, decrypted by Argo CD; the age key offline in two places | Add ESO for secrets that must be shared with AWS-side systems; platform-internal secrets can stay in SOPS |
| Roles Anywhere | Requested (see above) | Mirror host first, then ESO |
| ClearML server on AWS | **Reachable (confirmed).** The ClearML agent and SDK run on-prem; see "ClearML on-prem" below | – |
| S3 offsite copy | Off-cluster **backup box** (NAS or spare server) with restic or Kopia, append-only | S3 bucket with object lock as a third copy |
| OpenTofu | Not usable without IAM create rights; document the requested resources in the repo instead, so the IAM owners can apply them | Adopt when you get rights, or hand the modules to the IAM owners |
| EKS / MultiKueue | Deferred: needs VPN/DX | Unchanged from the design |

### ClearML on-prem: where the client runs, and which credentials it needs

A ClearML task needs two things where it runs: the **ClearML SDK** inside the job's image, and a **ClearML agent** that pulls tasks from a ClearML queue and starts them. It may need up to two kinds of credentials:

| Credential | Needed for | When |
|---|---|---|
| ClearML API key and secret (plus the server URLs) | The agent pulling tasks; the SDK reporting metrics and logs | Always |
| AWS credentials | Uploading and downloading artifacts or models, **only if** the task's output URI or files server is `s3://…` | Only with S3 storage |

**Where the agent should run:**
- **Target (as in the design):** the ClearML **Kubernetes glue**, one per team namespace. It turns each ClearML task into a pod carrying the team's Kueue queue label, so ClearML work gets the same quota, preemption, failure requeue and job records as everything else.
- **Interim, before Kubernetes is up:** your idea of a container on bare metal works as a stopgap. Run `clearml-agent` in Docker mode, under a dedicated service account (not a person), as a systemd service on **one designated node**. Write it down as temporary. While it runs it bypasses quota, so the job recorder will see it as a service-origin job. Retire it when the glue is live in phase 6.

**Credentials, following the same rule as ECR (no personal credentials on machines):**
- **ClearML keys:** one ClearML service account per team, so access can be revoked and work attributed per team. Keep them in SOPS. They're delivered as a Kubernetes Secret to the glue, or, in the interim, as a root-owned environment file for the systemd unit. Never bake them into images or put them in user homes.
- **AWS credentials, only if artifacts go to S3:** request a dedicated machine identity (an IAM user, or a Roles Anywhere role later) limited to read/write on **one bucket prefix per team**. Add it to the same IAM request as the ECR read role. Inside the container, prefer `credential_process` with the signing helper once Roles Anywhere exists, so there are no static keys.
- **Consider keeping artifacts on-prem instead:** set the output URI to Ceph RGW's S3 endpoint. Then jobs need no AWS credentials at all, and large checkpoints don't cross the internet link. The trade-off: artifacts are only viewable from inside the network, and each user's ClearML web UI needs the RGW credentials configured to show them.

**Images:**
- Build job images with the ClearML SDK and the usual dependencies pre-installed, and pull them through Harbor.
- Avoid letting the agent `pip install` requirements at every task start. It's slow, depends on the internet, and isn't reproducible. If some runtime installs are unavoidable, put a Python package proxy/cache on-prem.

**TLS:** if the company lets you use a real domain with a DNS API, issue public certificates via ACME DNS-01 (internet is OK). That avoids distributing a private CA to every laptop, browser and container. Otherwise use an offline root plus an intermediate used by cert-manager, with the root pushed to nodes by Ansible.

### Time sync with outbound NTP blocked

Clock agreement isn't optional here. Several parts of the stack fail when clocks drift:

| What breaks with skew | Tolerance |
|---|---|
| AWS API calls (SigV4): Harbor's ECR sync, Roles Anywhere | Rejected beyond **5 min** |
| OIDC tokens from Keycloak (`iat`, `exp`, `nbf`), checked by the API server, Argo CD and Grafana; laptops vs servers | Usually seconds to a minute |
| TLS certificates, especially short-lived cert-manager ones ("not yet valid") | Seconds to minutes |
| etcd and RKE2 health checks (etcd warns on peer clock difference) | ~1 s warning |
| Cross-node correlation of job records, Tetragon audit and Loki logs | The tighter the better |

**Without any outside reference, chrony's "local" mode keeps the nodes agreeing with each other, but they all drift from real time.** Typical drift is 1–4 s per day, so AWS calls start failing within weeks and laptop logins get flaky. You need **two internal time servers** plus **one real upstream reference**.

**Design:**
- **Two chrony time servers** run as host services: one CPU node, plus the backup box or a second CPU node. Each peers with the other, and both run in orphan mode, so if the upstream disappears they keep serving one consistent time instead of splitting.
- **Every node, the backup box, the NAS and the BMCs** sync from those two.
- Clients may **step the clock only at boot**; after that they slew. `rtcsync` keeps hardware clocks close for cold starts.
- **Upstream reference for the two servers,** in order of preference:
  1. **Ask the network team** whether there's an internal NTP source (the firewall, core router or switch often serves one). If not, ask for an exception allowing UDP 123 **from the two time-server IPs only** to two or three named servers. That's a small, auditable exception and the best result.
  2. **A GPS/PPS receiver** on one time server: true stratum 1, with no network dependency and immune to internet outages. It needs an antenna with sky view; a window is often enough.
  3. **HTTPS time as a fallback:** `htpdate` (or similar) on the two time servers only, reading the `Date` header from several well-known HTTPS sites over 443, which is allowed. Accuracy is sub-second, which is enough for everything in the table above. Caveat: if a clock is badly wrong, TLS validation can fail before time is fixed, so set the clock roughly from the BMC/RTC first and test the cold-start case in the lab.
- **Laptops** may sync to time.windows.com or Apple time over UDP 123, which is blocked. Check how users' machines get time. Kubelogin and the browser logins compare token times against the laptop clock.

**Monitoring:**
- Alert on each node's offset from the time servers (over 100 ms) and on unsynchronised status. node-exporter's timex collector or a chrony exporter both provide these.
- Alert when the time servers lose their upstream (orphan mode). That gives you days of warning before AWS calls start failing.

### Recovery targets to agree up front (starting points)

| Data / state | Where it lives | Backup | RPO | RTO |
|---|---|---|---|---|
| Platform config | Git (hosted outside, plus a local mirror on the backup box) | Mirror | 0 | Rebuild time (measure it) |
| Cluster state | etcd | RKE2 snapshots **hourly**, to local disk + Ceph RGW + backup box | 1 h | 1–2 h |
| Keycloak, job records | PostgreSQL (CNPG) | Continuous WAL + daily base backup to RGW; nightly dump to the backup box | ~5 min | 1 h |
| Job checkpoints | CephFS / RGW | Per-job checkpoint interval; important buckets copied to the backup box | Checkpoint interval | Requeue |
| Homes | CephFS `/home` | Scheduled snapshots; off-cluster copy only if the backup box fits it | 1 h (snapshots) | Minutes (self-restore from `.snap`) |
| Datasets / projects | CephFS | None for re-downloadable data; snapshots for the rest | Decide per dataset | – |
| Ceph itself | MON store, keyrings, config | Config and keyring backup on the backup box | – | Hours (rebuild MONs from OSDs: practise this in the lab) |
| Images | ECR (source of truth) → Harbor mirror | Harbor re-syncs from ECR; back up Harbor's database nightly | 24 h | 1 h (longer if AWS or the internet is also down: only already-mirrored images start) |
| Audit logs | Loki on RGW | Retention policy; copy if required by policy | 24 h | Best effort |
| Secrets | SOPS in Git | age key offline × 2 | 0 | Minutes |

Add a **"backup is fresh" alert** for each row: it fires if the newest backup is older than RPO × 1.5. Also send Alertmanager's Watchdog heartbeat to something outside the cluster, so a dead monitoring stack gets noticed.

### Phases

Each phase is done in the lab first, then on real nodes. Don't move on until its exit drill passes.

**Phase 0 — Prerequisites and decisions (no installs)**
- Inventory: which 3 nodes become CPU servers, which GPU nodes join first, which stay ad hoc for now.
- Network: static IPs, the VIP and LB pool, internal DNS names (`api`, `registry`, `s3`, `sso`, …).
- **Time source:** pick the upstream reference (network-team exception, GPS, or HTTPS fallback; see "Time sync") and send the request now.
- BMC/IPMI or console access to every node, and a UPS, with the cold-start order written down.
- A backup box, separate from the cluster nodes (sized for the critical set in §2, plus homes if possible).
- **Disk inventory per node:** device, SSD/HDD, size, SMART health, free bays. Then the capacity sum from §2, and the decision on what gets 3 copies.
- **Network:** a second NIC per node for a Ceph cluster network? Raise the 10 GbE request.
- Git host (SaaS is fine with internet) and where the local mirror lives.
- **AWS requests, sent now:** a machine identity for the mirror host (Roles Anywhere role, or an IAM user as fallback) with ECR read only; the list of existing ECR repos you can use.
- ECR and the ClearML server are reachable from on-prem (confirmed). Still to check: **where ClearML stores artifacts and models** (its own fileserver, or `s3://`), which decides whether jobs need AWS credentials.
- The UID/GID registry, from the UID audit above.
- Decisions to write up as ADRs: Keycloak + Ansible accounts; local registry; SOPS; Ceph (supersedes ADR-0004 Garage) and the disk layout; backup target; Ray/MPI/Slurm (§4).
- Build the lab VMs.

**Phase 1 — Hosts and out-of-cluster services**
- **The two chrony time servers first,** then the Ansible base role: chrony client pointing at them, packages, firewall, kernel and cgroup v2 settings.
- **Break-glass admin accounts** with SSH keys on every node.
- The POSIX user accounts from the registry.
- **Rolling per-node rebuild:** reimage a node with the local LVM layout (§2) via Ansible; its spare disks become Ceph OSDs. Start with the 3 CPU nodes.
- **Ceph via cephadm:** MONs and MGRs on the CPU nodes; OSDs on the pooled disks; device-class pools; recovery throttling; CephFS with the `home` area; RGW for S3.
- **Shared `/home`** mounted on every node, ad hoc ones included. Migrate homes user by user (§2 steps), with quota alerts on and snapshots scheduled.
- Harbor as a host service: proxy-cache projects for ECR and the public registries; OIDC login via Keycloak added in phase 4 (local admin until then).
- Optional interim: `clearml-agent` in Docker mode as a systemd service on one designated node, with per-team ClearML service-account keys from SOPS.
- Backup box jobs: the critical set from §2, and the Git mirror.
- Exit: every host is within 100 ms of the time servers, and they keep serving with the upstream cut. Power off one node: `/home` stays readable and writable, and Ceph recovers within the throttled rate (time it). A test user hits 80% of quota and the alert fires. Restore a file from a home snapshot. Restore a test file from the backup box. Harbor serves a mirrored ECR image with the internet unplugged.

**Phase 2 — Kubernetes core**
- RKE2 HA: 3 servers on CPU nodes with etcd on SSD/NVMe, kube-vip, Cilium.
- Hourly etcd snapshots to local disk and Ceph RGW.
- `kube-reserved` and `system-reserved`, and eviction thresholds.
- Join 1–2 GPU nodes as tainted agents.
- Store the break-glass kubeconfig offline.
- Exit: power off a server and the API stays up within 30 s. **In the lab, restore etcd from a snapshot onto rebuilt servers, and time it.**

**Phase 3 — GitOps, secrets, monitoring**
- Argo CD bootstrapped once by hand, with SOPS decryption.
- cert-manager and the TLS approach chosen above.
- kube-prometheus-stack with alerts for etcd health and fsync latency, disk, certificate expiry (30 days), node down, backup freshness, and clock offset / time-server upstream lost.
- Watchdog heartbeat to something external.
- Exit: delete an Argo CD-managed object and it self-heals; a cert-expiry test alert fires.

**Phase 4 — Identity and policy**
- Keycloak on CNPG with WAL archiving.
- Realm, groups and clients for: the API server (kubelogin), Argo CD, Grafana, the registry, oauth2-proxy.
- Team namespaces with RBAC from Keycloak groups.
- Kyverno: Pod Security Standards; images only from the local registry; queue label required; user label stamped; the `runAsUser`/UID rule.
- Exit: log in with kubectl via Keycloak. Stop Keycloak, then confirm SSH and the break-glass kubeconfig still work. Restore Keycloak's DB to a point in time in the lab.

**Phase 5 — GPU and storage**
- GPU Operator and NFD; NPD GPU check; ceph-csi against the external Ceph (CephFS for shared volumes, RBD for block); Velero to RGW.
- Exit: GPU nodes labelled by model; a namespace restore via Velero works.

**Phase 6 — Scheduling and the first pilot team**
- Kueue (flavors, cohort, `waitForPodsReady`, TAS if the version supports it), KubeRay, MPI Operator.
- Job templates with a checkpointing contract.
- ClearML Kubernetes glue for the pilot team; retire the interim bare-metal agent for that team.
- One pilot team only.
- Exit: borrow-and-reclaim demo; kill a GPU node mid-job, and it requeues and resumes from checkpoint.

**Phase 7 — Visibility and SSH containment**
- Tetragon, Alloy and Loki; the job recorder and its PostgreSQL.
- Designate the interactive nodes; per-user slices.
- Exit: the visibility drills in design §12.

**Phase 8 — Migrate the ad hoc nodes (blue/green)**
- Move one team at a time, once that team's homes and data are on CephFS with corrected ownership.
- Then drain the remaining ad hoc nodes, reimage them, and join them with Ansible. SSH stays only on the interactive nodes.
- Exit: every node is in the cluster or designated interactive, and nobody runs heavy work elsewhere (the off-limits alert is quiet).

**Phase 9 — Cold-start and rebuild drills, then quarterly**
- Full power-off and cold start, in the documented order: network/DNS → time servers → Ceph (MONs, OSDs, MDS) → registry → servers → agents → verify.
- A rebuild-from-Git drill in the lab.
- Record the times as your real RTO.

**Later — AWS, as rights arrive:** move the mirror's credential to Roles Anywhere if it started as an IAM user; Secrets Manager via ESO; S3 offsite copy with object lock; then VPN and EKS/MultiKueue. Keep the phase-1 prep from the design (names, CIDRs, Kueue version pinning) so this stays additive.

### Day-2 rules that keep it stable
- Pin every version. Change one component at a time, lab first.
- **RKE2:** upgrade one minor version at a time, servers one by one, with an etcd snapshot first.
- **GPU drivers:** upgrade node by node with a drain.
- **Kueue upgrades:** read CRD and API changes before each one.
- Put a maintenance window and a rollback note in every platform PR.

---

## 4. Ray vs Slurm

### They aren't the same kind of tool
- **Ray** is a distributed compute framework: a Python API with tasks and actors, plus Ray Train, Tune, Data and Serve. It needs something underneath to give it machines.
- **Slurm** is a workload manager: queues, fair-share, accounting, backfill, job arrays, and MPI launch via `srun`/PMIx. It competes with **Kubernetes + Kueue**, not with Ray. Ray can run on either.

So the real question is which resource manager you run, and which framework you offer on top. The current design already has Ray (KubeRay, admitted by Kueue) as the main ML path, so your colleague's preference is already in it.

### Why not Slurm as the base here
- **Two control planes on 8 nodes.** Running Slurm and Kubernetes means either splitting the nodes (wasting GPUs that sit idle in the other partition) or having two schedulers fight over the same hardware. Slinky (Slurm on Kubernetes) narrows this gap but is still a second scheduler and accounting system to run and learn.
- **Everything else in the design is Kubernetes-native:** containers from the registry, Kyverno policy, Argo CD, Ray dashboards, services and notebooks, and the future EKS/MultiKueue path. Slurm is weaker at long-running services and containers; it needs Pyxis/enroot or Apptainer.
- **Stability:** HA for Slurm (a shared state directory for slurmctld failover, slurmdbd on MariaDB) is another stateful stack to back up and drill.

### Where Slurm is genuinely better (take this seriously for your HPC users)
- `sbatch`/`srun` ergonomics, job arrays, backfill, and mature fair-share and accounting (`sacct`, `sshare`).
- Tight-coupled MPI on bare metal, especially with InfiniBand/RDMA.
- Decades of operational maturity, and HPC users already know it.

### Recommendation for a mixed workload
- **One resource manager: Kubernetes + Kueue.** Quota, fair sharing and preemption across everyone.
- **ML users → Ray via `RayJob`**, one ephemeral Ray cluster per job, with datasets staged to local `/scratch` and checkpoints to CephFS or RGW. Use a long-lived `RayCluster` only for interactive work, capped inside the team quota.
  - Ray stability notes: pin Ray in the job image (head and workers must match), and check KubeRay ↔ Ray version compatibility.
  - Use Ray Train's failure/restart settings with checkpoints.
  - Enable GCS fault tolerance (external Redis) only for long-lived clusters, not batch jobs.
- **MPI users → `MPIJob`** (MPI Operator), with an MPI-enabled base image you maintain. Over plain Ethernet, TCP MPI is fine for moderate coupling.
- **Bridge for `sbatch` habits:** evaluate Kueue's `kjobctl` Slurm mode, which runs `#SBATCH` scripts as Kubernetes Jobs. It's experimental, so verify its maturity in your pinned version. Alternatively, write a thin `sbatch`-style wrapper around job templates.
- **Interactive nodes over SSH** stay available for people who need a shell and can't containerise yet. Their work is recorded, not scheduled.

### Write down when you'd revisit Slurm (via Slinky on dedicated nodes)
Any of these:
- MPI/HPC work is a large, steady share of GPU-hours (say over 30%) and users are blocked by MPIJob ergonomics.
- You add InfiniBand/RDMA and need topology-aware MPI placement beyond Kueue TAS.
- Job arrays or accounting needs that Kueue and the job recorder can't meet.

Put these criteria in the Ray/MPI/Slurm ADR, so the decision can be reopened on evidence.

---

## Docs to update when you're ready (you or me, your call)
- New ADRs: Keycloak + Ansible POSIX accounts; local registry; SOPS secrets; Ceph and the local disk layout (supersedes ADR-0004); 1 GbE as a known limit; backup box and RPO/RTO; Ray + MPIJob on Kueue, with the criteria for revisiting Slurm.
- Revise ADR-0003: ECR stays the source of truth, with a Harbor mirror instead of a credential provider on every node.
- Mark ADR-0005 (Roles Anywhere) as "requested", with the IAM-user fallback.
- Mark ADR-0011 (OpenTofu) as deferred until you have IAM rights, or as handed to the IAM owners.
- `cluster_design.md`: §1 constraints, §5–6 (AWS), §8.4 (SSH via Ansible accounts, not SSSD), §10 stack table, §11 phases.
- `implementation.md`: replace the phase list with the one above, and add the cold-start order.
- The published page: figures 1 and 6 change (identity and AWS boxes).

## Verification
For this advice, verification is the drills themselves. Each phase's exit check is the test, and phase 9's cold-start and rebuild times become the RTO you report. Check these against your pinned versions before relying on them:
- structured authentication config
- `kjobctl` Slurm mode
- Harbor's ECR endpoint (auth method, token refresh) and its proxy-cache behaviour
- The current stable Ceph release and its cephadm upgrade path
- CephFS quota support in your kernel client
- mClock recovery settings in that release
- the Keycloak upgrade path
- KubeRay ↔ Ray compatibility
