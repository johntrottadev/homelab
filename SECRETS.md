# Kubernetes Secrets

This document enumerates every Kubernetes Secret used by this homelab cluster.
All secrets are applied **out-of-band** (not GitOps-managed) via `kubectl`. The
GitOps-via-sealed-secrets or sops pattern is tracked as a future milestone (NEXT-01);
for M1, out-of-band apply is the deliberate, single-operator-appropriate choice.

---

## The `*-creds.template` Pattern

The canonical apply pattern for multi-key secrets in this repo:

1. Find the `*.template` file committed in the relevant app subdirectory
2. Copy it to the same path without the `.template` suffix (this filename is gitignored)
3. Edit the real values in-place
4. Apply with `kubectl apply -f <secret-file>`

```bash
# Example (Palo Alto firewall credentials):
cp clusters/default/netalert/secret-paloarp-creds.template \
   clusters/default/netalert/secret-paloarp-creds
# edit PALO_HOST, PALO_API_KEY in the copy
kubectl apply -f clusters/default/netalert/secret-paloarp-creds
```

The `.gitignore` deny+allow pair ensures:
- `secret-paloarp-creds` (real values) — gitignored, **never committed**
- `secret-paloarp-creds.template` (REPLACE_ME placeholders) — committed, safe to publish

**Canonical examples of this pattern in the repo:**
- `velero/wasabi-creds.template` — INI-format credentials for Velero's Wasabi BackupStorageLocation
- `clusters/default/netalert/secret-paloarp-creds.template` — k8s Secret YAML with `stringData`

---

## Secrets With Existing Templates

Five secrets have committed `*.template` files. Follow the `*-creds.template` pattern above for each.

### 1. `paloarp-credentials` — namespace: `netalert`

**Consumer:** `netalert` Deployment (envFrom secretRef)  
**Template:** `clusters/default/netalert/secret-paloarp-creds.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `PALO_HOST` | Palo Alto firewall management IP | Your firewall's management interface IP |
| `PALO_API_KEY` | PA XML API key | `curl -k "https://<pa>/api/?type=keygen&user=<u>&password=<p>"` |
| `PALO_VERIFY_TLS` | TLS verification (true/false) | Set `false` for self-signed PA certs |

```bash
cp clusters/default/netalert/secret-paloarp-creds.template \
   clusters/default/netalert/secret-paloarp-creds
# edit values
kubectl apply -f clusters/default/netalert/secret-paloarp-creds
```

---

### 2. `nextcloud-secrets` — namespace: `nextcloud`

**Consumer:** `nextcloud` Deployment (envFrom secretRef)  
**Template:** `clusters/default/nextcloud/secret-nextcloud.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `POSTGRES_PASSWORD` | PostgreSQL database password | Generate: `openssl rand -base64 24 \| tr -d '/+='` |
| `NEXTCLOUD_ADMIN_USER` | Nextcloud admin username | Choose (e.g., `admin`) |
| `NEXTCLOUD_ADMIN_PASSWORD` | Nextcloud admin password | Generate: `openssl rand -base64 24 \| tr -d '/+='` |

```bash
cp clusters/default/nextcloud/secret-nextcloud.template \
   clusters/default/nextcloud/secret-nextcloud
# edit values
kubectl apply -f clusters/default/nextcloud/secret-nextcloud
```

---

### 3. `nextcloud-rclone-wasabi` — namespace: `nextcloud`

**Consumer:** `nextcloud-rclone-sync` CronJob (uses Wasabi S3 credentials for rclone)  
**Template:** `clusters/default/nextcloud/secret-rclone-wasabi.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `ACCESS_KEY_ID` | Wasabi access key ID | Wasabi console > Access Keys (reuse Velero bucket key if appropriate) |
| `SECRET_ACCESS_KEY` | Wasabi secret access key | Same Wasabi key as above |

```bash
cp clusters/default/nextcloud/secret-rclone-wasabi.template \
   clusters/default/nextcloud/secret-rclone-wasabi
# edit values
kubectl apply -f clusters/default/nextcloud/secret-rclone-wasabi
```

---

### 4. `firefly-secrets` — namespace: `firefly`

**Consumer:** `firefly` Deployment (envFrom secretRef)  
**Template:** `clusters/default/firefly/secret.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `APP_KEY` | Firefly III application key | Generate: `openssl rand -base64 32` |
| `POSTGRES_PASSWORD` | PostgreSQL database password | Generate: `openssl rand -base64 24 \| tr -d '/+='` |
| `STATIC_CRON_TOKEN` | Cron sidecar auth token | Generate: `openssl rand -hex 16` |

```bash
cp clusters/default/firefly/secret.template \
   clusters/default/firefly/secret-firefly
# edit values
kubectl apply -f clusters/default/firefly/secret-firefly
```

---

### 5. `velero-wasabi-creds` — namespace: `velero`

**Consumer:** Velero BackupStorageLocation (Wasabi S3-compatible endpoint)  
**Template:** `velero/wasabi-creds.template`  
**Keys:** INI-format AWS credentials file

| Key | Description | Source |
|-----|-------------|--------|
| `aws_access_key_id` | Wasabi access key ID | Wasabi console > Access Keys > Create key for `__WASABI-BUCKET__` bucket |
| `aws_secret_access_key` | Wasabi secret access key | Shown once at key creation; store securely |

```bash
cp velero/wasabi-creds.template velero/wasabi-creds
# edit values
kubectl create secret generic velero-wasabi-creds \
  --namespace velero \
  --from-file=cloud=velero/wasabi-creds
```

> Note: Velero expects the credentials file mounted at a key named `cloud` (the `--from-file=cloud=` flag sets this). The template uses INI format, not YAML.

---

## Secrets With New Templates (Phase 4)

Five additional secrets now have `*.template` files created in Phase 4. Follow the
same `*-creds.template` pattern.

### 6. `fitjat-secrets` — namespace: `fitjat`

**Consumer:** `fitjat` Deployment (envFrom secretRef)  
**Template:** `clusters/default/fitjat/secret-fitjat.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `GITHUB_CLIENT_ID` | GitHub OAuth App client ID | GitHub > Settings > Developer settings > OAuth Apps > New OAuth App |
| `GITHUB_CLIENT_SECRET` | GitHub OAuth App client secret | GitHub > OAuth App > Client secrets > Generate a client secret |
| `NEXTAUTH_SECRET` | NextAuth.js session signing secret | Generate: `openssl rand -base64 36` |

**Callback URL for OAuth App:** `https://fitjat.<your-domain>/api/auth/callback/github`

```bash
cp clusters/default/fitjat/secret-fitjat.template \
   clusters/default/fitjat/secret-fitjat
# edit values
kubectl apply -f clusters/default/fitjat/secret-fitjat
```

---

### 7. `hoarder-secrets` — namespace: `hoarder`

**Consumer:** `web` and `meilisearch` Deployments (envFrom secretRef)  
**Template:** `clusters/default/hoarder/secret-hoarder.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `NEXTAUTH_SECRET` | NextAuth.js session signing secret | Generate: `openssl rand -base64 36` |
| `MEILI_MASTER_KEY` | Meilisearch master key | Generate: `openssl rand -base64 36` (must match meilisearch startup) |

> Note: `NEXT_PUBLIC_SECRET` was dropped in Phase 1 (not read by Karakeep v0.31+).
> GitHub OAuth uses `OAUTH_CLIENT_ID`/`OAUTH_CLIENT_SECRET` in current Karakeep — add
> to the template if enabling GitHub login.

```bash
cp clusters/default/hoarder/secret-hoarder.template \
   clusters/default/hoarder/secret-hoarder
# edit values
kubectl apply -f clusters/default/hoarder/secret-hoarder
```

---

### 8. `pushover-creds` — namespace: `monitoring`

**Consumer:** `kube-prometheus-stack` HelmRelease (Alertmanager) and `fitjat-backup-health` CronJob  
**Template:** `clusters/default/monitoring/secret-pushover.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `token` | Pushover application API token | pushover.net > Your Applications > Register an Application |
| `user_key` | Pushover user/group key | pushover.net dashboard (shown after login) |

> Alertmanager mounts this secret as a file volume; key names must be exactly `token`
> and `user_key` to match the file paths configured in the HelmRelease.

```bash
cp clusters/default/monitoring/secret-pushover.template \
   clusters/default/monitoring/secret-pushover
# edit values
kubectl apply -f clusters/default/monitoring/secret-pushover
```

---

### 9. `grafana-admin-credentials` — namespace: `monitoring`

**Consumer:** `kube-prometheus-stack` HelmRelease (Grafana)  
**Template:** `clusters/default/monitoring/secret-grafana-admin.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `admin-user` | Grafana admin username | Choose (e.g., `admin`) |
| `admin-password` | Grafana admin password | Generate: `openssl rand -base64 24 \| tr -d '/+='` |

```bash
cp clusters/default/monitoring/secret-grafana-admin.template \
   clusters/default/monitoring/secret-grafana-admin
# edit values
kubectl apply -f clusters/default/monitoring/secret-grafana-admin
```

---

### 10. `backup-host-exporter-credentials` — namespace: `monitoring`

**Consumer:** `backup-host-exporter` Deployment (secretKeyRef × 3)  
**Template:** `clusters/default/monitoring/secret-backup-host-exporter.template`  
**Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `username` | PBS API token owner (user@realm) | PBS web UI > Administration > API Tokens > user field |
| `token-name` | API token name (label) | PBS web UI > Administration > API Tokens > token name |
| `token-secret` | API token secret value | Shown once at PBS token creation time |

> The PBS endpoint URL is configured as a plain env var in the Deployment spec
> (`PBS_ENDPOINT`), not in this Secret. Update it directly in
> `clusters/default/monitoring/backup-host-exporter/deployment.yaml`.

```bash
cp clusters/default/monitoring/secret-backup-host-exporter.template \
   clusters/default/monitoring/secret-backup-host-exporter
# edit values
kubectl apply -f clusters/default/monitoring/secret-backup-host-exporter
```

---

## Secrets Without Templates (kubectl one-liners)

These secrets have single or few keys with straightforward value sources.
Apply each with `kubectl create secret generic`.

### 11. `cloudflared-token` — namespace: `fitjat`

**Consumer:** `cloudflared` Deployment (secretKeyRef key: `token`)

```bash
kubectl create secret generic cloudflared-token \
  --namespace fitjat \
  --from-literal=token=<CLOUDFLARE_TUNNEL_TOKEN>
```

> **Source:** Cloudflare Zero Trust dashboard > Networks > Tunnels > `<your-tunnel>` >
> Configure > Install and run a connector > Copy the tunnel token from the `--token` argument.

---

### 12. `db-secret` — namespace: `homarr`

**Consumer:** `homarr` Deployment (secretKeyRef key: `SECRET_ENCRYPTION_KEY`)

```bash
kubectl create secret generic db-secret \
  --namespace homarr \
  --from-literal=SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32)
```

> **Source:** Generate locally. This key encrypts Homarr's local SQLite database.
> Store it safely — losing it requires a database reset.

---

### 13. `guacamole-db-credentials` — namespace: `guacamole`

**Consumer:** `guacamole-db` (postgres) and `guacamole` Deployments (secretKeyRef key: `postgres-password`)

```bash
kubectl create secret generic guacamole-db-credentials \
  --namespace guacamole \
  --from-literal=postgres-password=$(openssl rand -base64 24 | tr -d '/+=')
```

> **Source:** Generate locally. Used as the PostgreSQL password for Guacamole's database.

---

### 14. `paperless-secret` — namespace: `paperless`

**Consumer:** `paperless` Deployment (secretKeyRef keys: `admin-user`, `admin-password`, `db-password`)

```bash
kubectl create secret generic paperless-secret \
  --namespace paperless \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=$(openssl rand -base64 24 | tr -d '/+=') \
  --from-literal=db-password=$(openssl rand -base64 24 | tr -d '/+=')
```

> **Source:** Generate locally. `admin-user` is the Paperless-ngx web admin username.

---

### 15. `vscode-secret` — namespace: `vscode`

**Consumer:** `vscode` Deployment (secretKeyRef key: `password`, used for both `PASSWORD` and `SUDO_PASSWORD`)

```bash
kubectl create secret generic vscode-secret \
  --namespace vscode \
  --from-literal=password=<STRONG_PASSWORD>
```

> **Source:** Choose a strong password. Both the web IDE login and the in-container
> sudo password use this value.

---

### 16. `pihole-exporter-credentials` — namespace: `monitoring`

**Consumer:** `pihole-exporter` Deployment (secretKeyRef key: `passwords`)

```bash
kubectl create secret generic pihole-exporter-credentials \
  --namespace monitoring \
  --from-literal=passwords=<PIHOLE_ADMIN_PASSWORD>
```

> **Source:** Pi-hole admin panel password. If you run two Pi-hole instances,
> the exporter accepts a comma-separated list of passwords (one per host, in the
> same order as `PIHOLE_HOSTNAME`).

---

### 17. `snmp-exporter-credentials` — namespace: `monitoring`

**Consumer:** `snmp-exporter` initContainer (renders SNMPv3 config via envsubst)  
**Keys:** Six keys — SNMPv3 credentials for Synology NAS and Palo Alto firewall

```bash
kubectl create secret generic snmp-exporter-credentials \
  --namespace monitoring \
  --from-literal=synology-username=<SYNO_SNMP_USER> \
  --from-literal=synology-auth-pass=<SYNO_SNMP_AUTH_PASS> \
  --from-literal=synology-priv-pass=<SYNO_SNMP_PRIV_PASS> \
  --from-literal=paloalto-username=<PA_SNMP_USER> \
  --from-literal=paloalto-auth-pass=<PA_SNMP_AUTH_PASS> \
  --from-literal=paloalto-priv-pass=<PA_SNMP_PRIV_PASS>
```

> **Source — Synology:** DSM > Control Panel > Terminal & SNMP > SNMP > Enable SNMP v3;
> create a user with AuthPriv security level and note the auth/priv passwords.
>
> **Source — Palo Alto:** Device > Server Profiles > SNMP V3; create an SNMPv3 user
> and note the auth/priv passwords. Auth protocol: SHA, Priv protocol: AES.

---

## Cert-Manager Issued Secrets

These are automatically provisioned by cert-manager and do **not** require manual application.

| Secret | Namespace | Issued By | Notes |
|--------|-----------|-----------|-------|
| `wildcard-<your-domain>` | `cert-manager`, `traefik` | ClusterIssuer (Cloudflare DNS-01) | Wildcard TLS cert used by all IngressRoutes |
| `wildcard-<your-domain>-staging` | `cert-manager` | Staging ClusterIssuer | Let's Encrypt staging cert for testing |

cert-manager issues these automatically when the ClusterIssuer is configured with a valid
Cloudflare API token and `BASE_DOMAIN` is set in `flux-system/cluster-vars.yaml`.
See `REPLICATE.md` for the cert-manager bootstrap sequence.

---

## Secret Application Order

Apply secrets roughly in this dependency order to avoid reconcile failures:

1. `cluster-vars` ConfigMap (not a Secret, but required first — see `REPLICATE.md` Step 3)
2. cert-manager ClusterIssuer Cloudflare token (prerequisite for wildcard cert issuance)
3. `velero-wasabi-creds` — Velero needs this before the BackupStorageLocation becomes `Ready`
4. `pushover-creds` and `grafana-admin-credentials` — required before kube-prometheus-stack HelmRelease reconciles cleanly
5. `backup-host-exporter-credentials` — required before backup-host-exporter pod starts
6. All other app secrets in any order — workloads will restart once their Secret is present

---

## Summary Table

| # | Secret | Namespace | Consumer | Template |
|---|--------|-----------|----------|----------|
| 1 | `paloarp-credentials` | `netalert` | netalert Deployment | `clusters/default/netalert/secret-paloarp-creds.template` |
| 2 | `nextcloud-secrets` | `nextcloud` | nextcloud Deployment | `clusters/default/nextcloud/secret-nextcloud.template` |
| 3 | `nextcloud-rclone-wasabi` | `nextcloud` | rclone-sync CronJob | `clusters/default/nextcloud/secret-rclone-wasabi.template` |
| 4 | `firefly-secrets` | `firefly` | firefly Deployment | `clusters/default/firefly/secret.template` |
| 5 | `velero-wasabi-creds` | `velero` | Velero BackupStorageLocation | `velero/wasabi-creds.template` |
| 6 | `fitjat-secrets` | `fitjat` | fitjat Deployment | `clusters/default/fitjat/secret-fitjat.template` |
| 7 | `hoarder-secrets` | `hoarder` | web + meilisearch Deployments | `clusters/default/hoarder/secret-hoarder.template` |
| 8 | `pushover-creds` | `monitoring` | Alertmanager + fitjat backup CronJob | `clusters/default/monitoring/secret-pushover.template` |
| 9 | `grafana-admin-credentials` | `monitoring` | Grafana (kube-prometheus-stack) | `clusters/default/monitoring/secret-grafana-admin.template` |
| 10 | `backup-host-exporter-credentials` | `monitoring` | backup-host-exporter Deployment | `clusters/default/monitoring/secret-backup-host-exporter.template` |
| 11 | `cloudflared-token` | `fitjat` | cloudflared Deployment | kubectl one-liner |
| 12 | `db-secret` | `homarr` | homarr Deployment | kubectl one-liner |
| 13 | `guacamole-db-credentials` | `guacamole` | guacamole-db + guacamole Deployments | kubectl one-liner |
| 14 | `paperless-secret` | `paperless` | paperless Deployment | kubectl one-liner |
| 15 | `vscode-secret` | `vscode` | vscode Deployment | kubectl one-liner |
| 16 | `pihole-exporter-credentials` | `monitoring` | pihole-exporter Deployment | kubectl one-liner |
| 17 | `snmp-exporter-credentials` | `monitoring` | snmp-exporter initContainer | kubectl one-liner |
| — | `wildcard-<your-domain>` | `cert-manager`, `traefik` | All IngressRoutes | cert-manager auto-issued |
| — | `wildcard-<your-domain>-staging` | `cert-manager` | Testing | cert-manager auto-issued |

---

## Deferred: Secrets as Code

In-tree encrypted secrets via sealed-secrets or sops are tracked as **NEXT-01**. The current
out-of-band `kubectl apply` pattern is deliberate for this single-operator deployment.

- Sealed Secrets: <https://github.com/bitnami-labs/sealed-secrets>
- SOPS: <https://getsops.io>
