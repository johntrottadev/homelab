# Velero Backup

File-level backup of app namespaces to Wasabi S3, using Kopia as the uploader.
Replaces Kasten K10 (removed due to GSB license gate in v7.x).

## Backup architecture

- **Schedules**: daily (7d TTL), weekly (28d TTL), monthly (365d TTL)
- **Target**: Wasabi `__WASABI-BUCKET__/velero` in `us-east-1`
- **Encryption**: Kopia client-side, passphrase-protected (passphrase in k8s Secret)
- **Scope**: all app namespaces except `flux-system`, `kube-system`, `default`
- **Excluded volumes** (via pod annotations):
  - `jellyfin/jellyfin` pod → `jellyfin-movies` volume (5TB media already on Hyper Backup)
  - `monitoring` prometheus TSDB volume (regeneratable)
- **Schedule times** (local cluster time):
  - Daily 03:00
  - Weekly Sunday 04:00
  - Monthly 1st of the month 05:00

## First-time install

### 1. Prepare credentials locally (gitignored)

```bash
cd velero/
cp wasabi-creds.template wasabi-creds
$EDITOR wasabi-creds   # fill in Wasabi access key + secret
```

`wasabi-creds` is in `.gitignore` — it will never be committed.

### 2. Install Velero on the cluster

From the repo root:

```bash
ssh bastion@__K3S-API-IP__ sudo kubectl create namespace velero

# Secret 1: Wasabi S3 credentials
scp velero/wasabi-creds bastion@__K3S-API-IP__:/tmp/wasabi-creds
ssh bastion@__K3S-API-IP__ '
  sudo kubectl create secret generic velero-wasabi-creds \
    --namespace velero \
    --from-file=cloud=/tmp/wasabi-creds
  rm /tmp/wasabi-creds
'

# Secret 2: Kopia repository passphrase
# (use the 32-char passphrase from the original planning session)
ssh bastion@__K3S-API-IP__ '
  read -rsp "Kopia passphrase: " PASS; echo
  sudo kubectl create secret generic velero-repo-credentials \
    --namespace velero \
    --from-literal=repository-password="$PASS"
  unset PASS
'

# Install via Helm
scp velero/values.yaml bastion@__K3S-API-IP__:/tmp/velero-values.yaml
ssh bastion@__K3S-API-IP__ '
  sudo helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
  sudo helm repo update
  sudo helm install velero vmware-tanzu/velero \
    --namespace velero \
    -f /tmp/velero-values.yaml \
    --kubeconfig /etc/rancher/k3s/k3s.yaml
'

# Apply schedules
scp velero/schedules/*.yaml bastion@__K3S-API-IP__:/tmp/
ssh bastion@__K3S-API-IP__ 'sudo kubectl apply -f /tmp/daily.yaml -f /tmp/weekly.yaml -f /tmp/monthly.yaml'
```

### 3. Apply volume excludes

**jellyfin movies** (5TB, already Hyper Backed):
```bash
ssh bastion@__K3S-API-IP__ '
  sudo kubectl patch deploy -n jellyfin jellyfin -p '"'"'
    {"spec":{"template":{"metadata":{"annotations":{"backup.velero.io/backup-volumes-excludes":"movies"}}}}}
  '"'"'
'
```

Or edit `jellyfin/deployment.yaml` to add the annotation to `spec.template.metadata.annotations` and apply from repo.

**Prometheus TSDB** (regeneratable):
```bash
# The Prometheus pod is managed by prometheus-operator.
# Patch the Prometheus CR:
ssh bastion@__K3S-API-IP__ '
  sudo kubectl patch prometheus -n monitoring prometheus --type=merge -p '"'"'
    {"spec":{"podMetadata":{"annotations":{"backup.velero.io/backup-volumes-excludes":"prometheus-prometheus-prometheus-db"}}}}
  '"'"'
'
```

Adjust the volume name if it differs (check with `kubectl get pod -n monitoring prometheus-prometheus-prometheus-0 -o yaml | grep -A3 volumeMounts`).

## Verify install

```bash
ssh bastion@__K3S-API-IP__ '
  sudo kubectl -n velero get deploy,ds,backupstoragelocation,schedule
'

# Expected:
#  - deployment.apps/velero        (1/1 Running)
#  - daemonset.apps/node-agent     (4/4 Running — one per k3s node)
#  - backupstoragelocation/wasabi  (Available)
#  - schedule/daily-apps, weekly-apps, monthly-apps
```

Check BSL connectivity:
```bash
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n velero get backupstoragelocation wasabi -o jsonpath="{.status.phase}"'
# Expect: Available
```

## Smoke test (before relying on schedules)

```bash
# Trigger an on-demand backup of n8n (small, isolated):
ssh bastion@__K3S-API-IP__ '
  cat <<EOF | sudo kubectl create -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  generateName: smoke-n8n-
  namespace: velero
spec:
  includedNamespaces: [n8n]
  defaultVolumesToFsBackup: true
  ttl: 24h
  storageLocation: wasabi
EOF
'

# Poll completion:
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n velero get backup -l velero.io/schedule-name!= -o wide | tail -5'
# Status should progress Pending → InProgress → Completed
```

Verify blobs appear in Wasabi:
```bash
aws --profile wasabi --endpoint https://__WASABI-ENDPOINT__ s3 ls s3://__WASABI-BUCKET__/velero/
```

## Restore procedure

### Restore a full namespace

```bash
# List available backups
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n velero get backup'

# Restore (new or different namespace name is allowed via namespaceMapping):
ssh bastion@__K3S-API-IP__ '
  cat <<EOF | sudo kubectl create -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  generateName: restore-n8n-
  namespace: velero
spec:
  backupName: <BACKUP-NAME-HERE>
  includedNamespaces: [n8n]
  restorePVs: true
EOF
'

# Poll:
ssh bastion@__K3S-API-IP__ 'sudo kubectl -n velero get restore'
```

### Restore specific resource types only

Use `includedResources: [configmaps, secrets]` in the Restore spec. Skip heavy PVCs by adding `excludedResources: [persistentvolumeclaims, persistentvolumes]`.

### Full cluster DR (recovery to a new cluster)

1. Install Velero on the new cluster with the **same** `wasabi-creds` and `repository-password`
2. Point to the same BSL (`bucket: __WASABI-BUCKET__, prefix: velero`)
3. List available backups: `velero backup get`
4. Run `velero restore create --from-backup <name>` per namespace

## Operational notes

- **Passphrase loss = data loss.** Kopia encrypts client-side. Store the passphrase in a password manager (1Password, Bitwarden, etc.), off the cluster.
- **First backup is slow** — every byte goes to Wasabi. Subsequent incrementals dedupe against prior blobs (Kopia content-addressed storage).
- **Wasabi egress** has no cost; reads during restore are free.
- **Node-agent must run on the node where the pod is.** Since we pin NFS-dependent apps to k3s-2 (see INFRASTRUCTURE.md), node-agent on k3s-2 reads those PVCs via kubelet's hostPath mounts.
- **Metrics** are scraped by the existing Prometheus via the ServiceMonitor in `values.yaml`. Grafana dashboard ID 11055 (or 15661).

## Upgrade procedure

```bash
# Pull latest chart
ssh bastion@__K3S-API-IP__ 'sudo helm repo update'

# Upgrade
scp velero/values.yaml bastion@__K3S-API-IP__:/tmp/velero-values.yaml
ssh bastion@__K3S-API-IP__ '
  sudo helm upgrade velero vmware-tanzu/velero \
    --namespace velero \
    -f /tmp/velero-values.yaml \
    --kubeconfig /etc/rancher/k3s/k3s.yaml
'
```

Schedules and secrets survive the upgrade.

## Uninstall (destructive)

```bash
ssh bastion@__K3S-API-IP__ '
  sudo helm uninstall velero -n velero --kubeconfig /etc/rancher/k3s/k3s.yaml
  sudo kubectl delete namespace velero
'
```

Wasabi data is retained. To wipe it:
```bash
aws --profile wasabi --endpoint https://__WASABI-ENDPOINT__ s3 rm s3://__WASABI-BUCKET__/velero --recursive
```
