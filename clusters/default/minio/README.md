# MinIO

Self-hosted S3-compatible object storage. Backs Nextcloud's primary
object storage; replaces the Wasabi `nextcloud-jt-lab` bucket as the
authoritative copy of user data.

## Architecture

```
┌──────────┐  S3 (HTTP, in-cluster)  ┌──────────────────┐
│Nextcloud │ ──────────────────────► │ MinIO (k3s pod)  │
└──────────┘                         └────────┬─────────┘
                                              │ NFS PVC
                                              ▼
                                     ┌──────────────────┐
                                     │ Synology NAS     │
                                     │ /volume1/kub/    │
                                     │   minio/         │
                                     └────────┬─────────┘
                                              │ Hyper Backup nightly
                                              ▼
                                     ┌──────────────────┐
                                     │ Wasabi (DR)      │
                                     │ encrypted        │
                                     │ archive          │
                                     └──────────────────┘
```

Three copies: live MinIO data, Synology RAID redundancy, Wasabi nightly
archive. Wasabi recovery goes through Hyper Backup (point-in-time, encrypted).

## Components

| Resource | Image | Notes |
|---|---|---|
| `Deployment minio` | `minio/minio:latest` | Single-server single-drive (SNSD), `Recreate` strategy |
| `Service minio` | — | Two ports: 9000 (S3 API, in-cluster only), 9001 (console) |
| `PV minio-pv` / `PVC minio-pvc` | — | NFS RWO at `/volume1/kub/minio`, 500Gi metadata |
| `IngressRoute minio-console` | — | `https://minio.__BASE-DOMAIN__` → port 9001. **S3 API is NOT exposed externally.** |

In-cluster S3 endpoint: `http://minio.minio.svc.cluster.local:9000`

## One-time setup (Synology side)

The NAS dir `/volume1/kub/minio` already exists (created during deploy
prep, owned by __NAS-USER__). MinIO will populate it on first start.

Hyper Backup config (do this once via DSM): include the share
`/volume1/kub/minio` in your existing nightly Wasabi backup task.
Without that, the offsite DR layer is missing.

## Deploy steps

### 1. Apply the root Secret

```bash
ssh bastion@__K3S-API-IP__ 'sudo kubectl create ns minio --dry-run=client -o yaml | sudo kubectl apply -f -'
ssh bastion@__K3S-API-IP__ 'sudo kubectl apply -f -' <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: minio-root
  namespace: minio
type: Opaque
stringData:
  MINIO_ROOT_USER: "mcadmin"
  MINIO_ROOT_PASSWORD: "<32-char random>"
EOF
```

### 2. Push the flux manifests

The flux `clusters/default/kustomization.yaml` lists this directory's
files. Once committed and reconciled, the deployment comes up.

### 3. Create the Nextcloud bucket + scoped service account

```bash
# Run a one-shot mc pod with root creds in env
ssh bastion@__K3S-API-IP__ 'sudo kubectl run -n minio mc --rm -i --restart=Never \
  --image=minio/mc:latest \
  --env=MC_HOST_local=http://mcadmin:<root-password>@minio.minio.svc:9000 \
  --command -- /bin/sh -c "
    mc mb local/nextcloud
    mc admin user svcacct add local mcadmin \
      --access-key <NC_KEY> --secret-key <NC_SECRET>
  "'
```

### 4. Update Nextcloud env to point at MinIO

Edit `clusters/default/nextcloud/deployment.yaml`:

```yaml
- name: OBJECTSTORE_S3_HOST
  value: minio.minio.svc.cluster.local
- name: OBJECTSTORE_S3_PORT
  value: "9000"
- name: OBJECTSTORE_S3_SSL
  value: "false"
- name: OBJECTSTORE_S3_BUCKET
  value: nextcloud
```

Update the `nextcloud-secrets` Secret with the new
`OBJECTSTORE_S3_KEY` and `OBJECTSTORE_S3_SECRET` (the MinIO svcacct
credentials, not Wasabi's anymore).

## Operational notes

### Adding more buckets for other apps

MinIO is a general-purpose object store; future apps can use it without
standing up another instance. Create a new bucket + scoped svcacct per
app, then point that app's S3 client at `http://minio.minio.svc:9000`.

### Console access

`https://minio.__BASE-DOMAIN__` → log in as `mcadmin` with the root password
(in the `minio-root` Secret). Use the console for ad-hoc bucket browsing,
policy editing, and inspecting access logs. Do NOT use root creds in
applications — always create a scoped svcacct.

### What happens if MinIO crashes

`Recreate` strategy + `livenessProbe` will restart the pod. Data lives
on NFS, so no data loss. Nextcloud uploads during the outage will fail
visibly to the client (PHP exception); existing files remain readable as
soon as MinIO is back.

### What happens if the NAS goes down

Both MinIO and Nextcloud lose access to their PVCs. Recovery: bring NAS
back. Nothing in the cluster needs touching. (The original NFS-primary
Nextcloud had the same dependency, so this isn't worse.)

### Image pinning

Once the running version is verified, pin it:
```yaml
image: minio/minio:RELEASE.2025-XX-XXTXX-XX-XXZ
```

## What is NOT here

- No multi-server / distributed MinIO — homelab scale doesn't justify it.
- No bidirectional replication to Wasabi — Hyper Backup covers DR.
- No bucket versioning — the few previous-version use cases are
  served by Nextcloud's own file-version history (which lives in
  Postgres, not in S3).
