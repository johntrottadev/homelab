# Nextcloud

Flux-managed Nextcloud deployment with filesystem-primary storage on NFS
and an object-level rclone mirror to Wasabi.

## Architecture

```
┌──────────┐  PHP write   ┌──────────────────┐
│Nextcloud │ ───────────► │ NFS (Synology)   │
└──────────┘              │ /volume1/kub/    │
                          │   homelab/       │
                          │   nextcloud/data │
                          └────────┬─────────┘
                                   │ rclone sync /15min
                                   ▼
                          ┌──────────────────┐
                          │ Wasabi           │
                          │ nextcloud-mirror │
                          │ object-keyed by  │
                          │ <user>/files/... │
                          └──────────────────┘
```

| Component | Image | Storage | Notes |
|---|---|---|---|
| `nextcloud` | `nextcloud:30-apache` | NFS PV `nextcloud-pvc` (`/var/www/html`, 20Gi) + `nextcloud-data-pvc` (`/var/www/html/data`, 500Gi) | Config + apps on small PV; user files on data PV |
| `nextcloud-postgres` | `postgres:16-alpine` | local-path PVC (20Gi) | Node-pinned for performance; daily pg_dump → NFS for safety |
| `nextcloud-redis` | `redis:7-alpine` | ephemeral | File locking + memcache |
| `nextcloud-postgres-backup` | `postgres:16-alpine` | NFS PV (10Gi) | Daily 02:15 UTC, 7-day retention |
| `nextcloud-cron` | `nextcloud:30-apache` | shares both PVCs | `php cron.php` every 5min |
| `nextcloud-rclone-wasabi` | `rclone/rclone:1.69` | data PVC mounted RO | `rclone sync` to `wasabi:nextcloud-mirror` every 15min |

User-file storage: NFS at `/volume1/kub/homelab/nextcloud/data/<user>/files/`. Each file is one POSIX file with its real name; the rclone CronJob mirrors that tree to Wasabi at object level so each file becomes one S3 object keyed by its real path. Wasabi is **standalone-restorable** — you can `rclone copy wasabi:nextcloud-mirror ./recovered` and have the entire user-file tree back, no Nextcloud or Postgres required.

Routing: `https://nextcloud.__BASE-DOMAIN__` via Traefik IngressRoute.

### Why filesystem-primary (not S3-primary)

Nextcloud's S3-primary mode stores every file as an opaque `urn:oid:<row-id>` object; the filename → oid mapping lives in the Postgres `oc_filecache` table. That makes any S3 mirror useless on its own — you'd need the cluster + Postgres to make sense of the bytes. We tried the chain Nextcloud → MinIO → Wasabi (April 2026); the Wasabi bucket ended up full of `urn:oid:N` blobs, defeating the point of an offsite mirror. Cutover to filesystem-primary on 2026-05-04 fixed that — Wasabi now contains the real files, browsable in any S3 client.

## One-time setup (do BEFORE flux reconciles, or it'll error)

### 1. Create NAS directories

SSH to a node that can mount the share, or do it from the NAS console:

```bash
ssh bastion@__K3S-API-IP__ "sudo mkdir -p /tmp/nasmount && \
  sudo mount -t nfs -o vers=4.1 __NAS-IP__:/volume1/kub/homelab /tmp/nasmount && \
  sudo mkdir -p /tmp/nasmount/nextcloud/config \
                /tmp/nasmount/nextcloud/data \
                /tmp/nasmount/nextcloud/postgres-backup && \
  sudo chown -R 33:33 /tmp/nasmount/nextcloud/config \
                      /tmp/nasmount/nextcloud/data && \
  sudo umount /tmp/nasmount && sudo rmdir /tmp/nasmount"
```

### 2. Apply the Secrets (out-of-band, paloarp pattern)

Two Secrets — Nextcloud creds and rclone Wasabi creds. Wasabi creds are
the same ones Velero uses; pull them from `velero-wasabi-creds`.

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

# Build the Nextcloud secret manifest (DO NOT commit)
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
EOF

# Build the rclone Wasabi secret manifest (DO NOT commit)
cat > /tmp/nextcloud-rclone-wasabi.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-rclone-wasabi
  namespace: nextcloud
type: Opaque
stringData:
  ACCESS_KEY_ID: "<paste aws_access_key_id from above>"
  SECRET_ACCESS_KEY: "<paste aws_secret_access_key from above>"
EOF

# Apply both
scp /tmp/nextcloud-secrets.yaml /tmp/nextcloud-rclone-wasabi.yaml \
    bastion@__K3S-API-IP__:/tmp/
ssh bastion@__K3S-API-IP__ 'sudo kubectl create ns nextcloud --dry-run=client -o yaml | sudo kubectl apply -f -'
ssh bastion@__K3S-API-IP__ 'sudo kubectl apply -f /tmp/nextcloud-secrets.yaml -f /tmp/nextcloud-rclone-wasabi.yaml'
ssh bastion@__K3S-API-IP__ 'rm /tmp/nextcloud-secrets.yaml /tmp/nextcloud-rclone-wasabi.yaml'
rm /tmp/nextcloud-secrets.yaml /tmp/nextcloud-rclone-wasabi.yaml

# Save the admin password somewhere safe — you won't see it again.
echo "Admin password: ${ADMINPASS}"
```

### 3. Let flux reconcile

Push the branch / let flux pull. Watch the rollout:

```bash
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n nextcloud get pods -w'
```

First boot of the `nextcloud` pod takes 1–3 minutes — it copies the web root onto the empty NFS volume and runs the installer. Watch logs:

```bash
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n nextcloud logs -f deploy/nextcloud'
```

Look for `Installation finished`. The data dir at `/var/www/html/data` is empty until the admin logs in for the first time.

### 4. Verify

```bash
# Status endpoint
curl -k -H "Host: nextcloud.__BASE-DOMAIN__" https://__K3S-VIP__/status.php
# Should return JSON with "installed":true, "maintenance":false
```

Then log in at `https://nextcloud.__BASE-DOMAIN__` with the admin credentials, upload a test file, and trigger the rclone job to confirm the Wasabi mirror is populating with real-named objects:

```bash
# Force one rclone run
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n nextcloud create job \
  --from=cronjob/nextcloud-rclone-wasabi rclone-test-$(date +%s)'
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n nextcloud logs -l job-name=rclone-test-* --tail=100'
```

Expected: at least one line like `INFO  : admin/files/Documents/test.txt: Copied (new)` and the object visible in Wasabi at `nextcloud-mirror/admin/files/Documents/test.txt`.

## Operational notes

### Restoring from Wasabi

Because the mirror is real-named, you can restore at any granularity:

```bash
# Restore one file
rclone copyto wasabi:nextcloud-mirror/admin/files/Documents/photo.jpg ./photo.jpg

# Restore one user
rclone copy wasabi:nextcloud-mirror/admin/ ./admin/

# Full DR — pull everything to a new NFS data dir
rclone copy wasabi:nextcloud-mirror/ /volume1/kub/homelab/nextcloud/data/
# Then `occ files:scan --all` to repopulate Postgres oc_filecache
```

### Wasabi 90-day minimum storage

Wasabi bills any object you store for at least 90 days, even if you delete it sooner. For a personal Nextcloud this is fine; just be aware before doing aggressive trash-emptying.

### Database recovery

Postgres holds usernames, share metadata, app config, file metadata (mtime, ownership, ETags). On total loss:

1. Restore Postgres from a Velero snapshot or the `postgres-backup` PVC dump.
2. Restore the data dir from Wasabi (see above).
3. `occ files:scan --all` to reconcile the filecache against what's on disk.

### Tuning if performance ever feels slow

1. Bump `redis-deployment.yaml` `--maxmemory` (it caches file metadata).
2. Postgres on local-path is the fast path; if you ever migrate to a DB cluster, point `POSTGRES_HOST` at it.
3. Image pull time on first deploy is usually the bottleneck — pre-pull on every node:
   ```bash
   for ip in 41 42 45 46; do ssh bastion@10.10.3.${ip} 'sudo crictl pull docker.io/nextcloud:30-apache'; done
   ```

### What is NOT here

- No Helm chart — chose plain manifests for transparency, mirrors the rest of the homelab.
- No HA / multiple replicas — `Recreate` strategy + single instance.
- No external-storage mounts (SMB/NFS-as-app-storage). Add via the Nextcloud admin UI later if needed.
- No MinIO — decommissioned 2026-05-04 with this cutover (no other consumers).
