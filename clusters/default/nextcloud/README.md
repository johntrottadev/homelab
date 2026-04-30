# Nextcloud

Flux-managed Nextcloud deployment with Wasabi S3 as primary object storage.

## Architecture

| Component | Image | Storage | Notes |
|---|---|---|---|
| `nextcloud` | `nextcloud:30-apache` | NFS PV (`/var/www/html`, 20Gi) | Config + apps only — user files go to Wasabi |
| `nextcloud-postgres` | `postgres:16-alpine` | local-path PVC (20Gi) | Node-pinned for performance; daily pg_dump → NFS for safety |
| `nextcloud-redis` | `redis:7-alpine` | ephemeral | File locking + memcache (REQUIRED for S3 primary) |
| `nextcloud-postgres-backup` | `postgres:16-alpine` | NFS PV (10Gi) | Daily 02:15 UTC, 7-day retention |
| `nextcloud-cron` | `nextcloud:30-apache` | shares `nextcloud-pvc` | `php cron.php` every 5min |

User-file storage: Wasabi S3 bucket `nextcloud-jt-lab` (auto-created on first start, region `us-east-1`).

Routing: `https://nextcloud.__BASE-DOMAIN__` via Traefik IngressRoute.

## One-time setup (do BEFORE flux reconciles, or it'll error)

### 1. Create NAS directories

SSH to a node that can mount the share, or do it from the NAS console:

```bash
ssh bastion@__K3S-API-IP__ "sudo mkdir -p /tmp/nasmount && \
  sudo mount -t nfs -o vers=4.1 __NAS-IP__:/volume1/kub/homelab /tmp/nasmount && \
  sudo mkdir -p /tmp/nasmount/nextcloud/config /tmp/nasmount/nextcloud/postgres-backup && \
  sudo chown -R 33:33 /tmp/nasmount/nextcloud/config && \
  sudo umount /tmp/nasmount && sudo rmdir /tmp/nasmount"
```

### 2. Apply the Secret (out-of-band, paloarp pattern)

The Wasabi credentials are already in the cluster (used by Velero). Pull them, then build a Nextcloud-shaped Secret.

```bash
# Extract Wasabi creds from Velero's secret
ssh bastion@__K3S-API-IP__ 'sudo kubectl get secret -n velero velero-wasabi-creds \
  -o jsonpath="{.data.cloud}" | base64 -d'
# Output is an AWS credentials file:
#   [default]
#   aws_access_key_id=AKIA...
#   aws_secret_access_key=...

# Pick strong random passwords for the others
PGPASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
ADMINPASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

# Build the secret manifest locally (DO NOT commit)
cat > /tmp/nextcloud-secrets.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-secrets
  namespace: nextcloud
type: Opaque
stringData:
  POSTGRES_PASSWORD: "${PGPASS}"
  NEXTCLOUD_ADMIN_USER: "admin"
  NEXTCLOUD_ADMIN_PASSWORD: "${ADMINPASS}"
  OBJECTSTORE_S3_KEY: "<paste aws_access_key_id from above>"
  OBJECTSTORE_S3_SECRET: "<paste aws_secret_access_key from above>"
EOF

# Apply
scp /tmp/nextcloud-secrets.yaml bastion@__K3S-API-IP__:/tmp/
ssh bastion@__K3S-API-IP__ 'sudo kubectl create ns nextcloud --dry-run=client -o yaml | sudo kubectl apply -f -'
ssh bastion@__K3S-API-IP__ 'sudo kubectl apply -f /tmp/nextcloud-secrets.yaml'
ssh bastion@__K3S-API-IP__ 'rm /tmp/nextcloud-secrets.yaml'
rm /tmp/nextcloud-secrets.yaml

# Save the admin password somewhere safe — you won't see it again.
echo "Admin password: ${ADMINPASS}"
```

### 3. Let flux reconcile

Once the Secret exists and the NAS dirs are present, push your branch / let flux pull. Watch the rollout:

```bash
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n nextcloud get pods -w'
```

First boot of the `nextcloud` pod takes 1–3 minutes — it copies the web root onto the empty NFS volume and runs the installer. Watch logs:

```bash
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n nextcloud logs -f deploy/nextcloud'
```

Look for `Installation finished` and `S3 object store ... bucket nextcloud-jt-lab`.

### 4. Verify

```bash
# Status endpoint
curl -k -H "Host: nextcloud.__BASE-DOMAIN__" https://__K3S-VIP__/status.php

# Should return JSON with "installed":true, "maintenance":false
```

Then log in at `https://nextcloud.__BASE-DOMAIN__` with the admin credentials.

## Operational notes

### S3 primary storage is one-way

Once Nextcloud writes any file to Wasabi, switching back to filesystem storage requires a manual data shuffle (no built-in migration tool). Don't change `OBJECTSTORE_S3_*` env vars after install without a deliberate plan.

After install you can flip `OBJECTSTORE_S3_AUTOCREATE` to `false` if you want — it's only consulted when the bucket doesn't exist.

### Wasabi 90-day minimum storage

Wasabi bills any object you store for at least 90 days, even if you delete it sooner. For a personal Nextcloud this is fine; just be aware before doing aggressive trash-emptying.

### Database recovery

If the local-path Postgres PV is lost (node death, disk failure):

```bash
# Find the latest dump
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n nextcloud exec deploy/nextcloud-postgres -- \
  ls -lh /backup' # NO — backups are on a different PVC, see below

# Backups live on the postgres-backup PVC; restore via a one-off pod that
# mounts both PVCs and pipes:
#   gunzip < /backup/nextcloud-YYYYMMDDTHHMMSSZ.sql.gz | psql -U nextcloud
# Detailed runbook lives in the homelab bastion doc; not duplicated here.
```

Velero also snapshots this namespace, so a `velero restore` is the other path.

### Tuning if performance ever feels slow

1. Bump `redis-deployment.yaml` `--maxmemory` (it caches file metadata; bigger = fewer DB hits).
2. Check `OBJECTSTORE_S3_OBJECT_CACHING` is enabled (defaults on with Redis).
3. Postgres on local-path is already the fast path; if you ever migrate to a DB cluster, point `POSTGRES_HOST` at it.
4. Image pull time on first deploy is usually the bottleneck — pre-pull on every node:
   ```bash
   for ip in 41 42 45 46; do ssh bastion@10.10.3.${ip} 'sudo crictl pull docker.io/nextcloud:30-apache'; done
   ```

### What is NOT here

- No Helm chart — chose plain manifests for transparency, mirrors the rest of the homelab.
- No HA / multiple replicas — `Recreate` strategy + single instance, simpler and avoids opcache races.
- No external-storage mounts (SMB/NFS-as-app-storage). Add via the Nextcloud admin UI later if needed.
