#!/usr/bin/env bash
# Kopia backup setup for a docker host. Snapshots /var/lib/docker/volumes plus
# any extra paths (compose stacks, komodo configs) to a per-host Kopia
# repository in Wasabi. Mirrors the existing Velero+Kopia data path used by k3s
# (same bucket, different prefix) so restores can be done with the same tool
# and credentials Velero already uses for k8s.
#
# Idempotent — re-runnable. Re-running rewrites /etc/kopia/env and the
# systemd unit but leaves the upstream repo and existing snapshots untouched.
#
# Usage (from a host that can SSH to the dock node):
#   KOPIA_PASSWORD=...        # shared across the dock fleet (save in pw mgr)
#   KOPIA_S3_ACCESS_KEY=...   # reuse velero-wasabi-creds value
#   KOPIA_S3_SECRET_KEY=...   # reuse velero-wasabi-creds value
#   ssh bastion@<dock-ip> \
#     "sudo KOPIA_PASSWORD=\"$KOPIA_PASSWORD\" \
#           KOPIA_S3_ACCESS_KEY=\"$KOPIA_S3_ACCESS_KEY\" \
#           KOPIA_S3_SECRET_KEY=\"$KOPIA_S3_SECRET_KEY\" bash -s" \
#     < kopia-backup.sh
#
# Required env vars:
#   KOPIA_PASSWORD          repository password — REQUIRED FOR RESTORES
#   KOPIA_S3_ACCESS_KEY     Wasabi access key (matches velero-wasabi-creds)
#   KOPIA_S3_SECRET_KEY     Wasabi secret key (matches velero-wasabi-creds)
#
# Optional overrides (defaults in []):
#   KOPIA_S3_BUCKET         [__WASABI-BUCKET__]
#   KOPIA_S3_ENDPOINT       [__WASABI-ENDPOINT__]
#   KOPIA_S3_REGION         [us-east-1]
#   KOPIA_S3_PREFIX         [dock/$(hostname)/]
#   KOPIA_PATHS             ["/var/lib/docker/volumes /opt/stacks /opt/komodo"]
#                           space-separated; missing dirs are skipped at run time
#   KOPIA_DAILY_AT          [03:30]   systemd OnCalendar HH:MM (offset from
#                                     velero's 03:00 to avoid Wasabi contention)
#   KOPIA_KEEP_DAILY        [7]
#   KOPIA_KEEP_WEEKLY       [4]
#   KOPIA_KEEP_MONTHLY      [12]
#
# What this DOES:
#   - installs kopia from packages.kopia.io apt repo
#   - writes /etc/kopia/env (creds + repo password, mode 0600)
#   - writes /etc/kopia/sources.list (operator-editable list of paths)
#   - connects (or creates) per-host repo at s3://$BUCKET/$PREFIX
#   - sets snapshot retention policy
#   - installs /usr/local/bin/kopia-backup-run.sh + systemd service+timer
#   - enables + starts the timer
#
# What this does NOT do:
#   - take a snapshot now (timer fires on schedule; run `systemctl start
#     kopia-backup.service` for an immediate test)
#   - back up arbitrary host paths outside KOPIA_PATHS — extend by editing
#     /etc/kopia/sources.list (one path per line)

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root (sudo bash kopia-backup.sh)." >&2
  exit 1
fi

: "${KOPIA_PASSWORD:?must be set — see header}"
: "${KOPIA_S3_ACCESS_KEY:?must be set — see header}"
: "${KOPIA_S3_SECRET_KEY:?must be set — see header}"

KOPIA_S3_BUCKET="${KOPIA_S3_BUCKET:-__WASABI-BUCKET__}"
KOPIA_S3_ENDPOINT="${KOPIA_S3_ENDPOINT:-__WASABI-ENDPOINT__}"
KOPIA_S3_REGION="${KOPIA_S3_REGION:-us-east-1}"
KOPIA_S3_PREFIX="${KOPIA_S3_PREFIX:-dock/$(hostname)/}"
KOPIA_PATHS="${KOPIA_PATHS:-/var/lib/docker/volumes /opt/stacks /opt/komodo}"
KOPIA_DAILY_AT="${KOPIA_DAILY_AT:-03:30}"
KOPIA_KEEP_DAILY="${KOPIA_KEEP_DAILY:-7}"
KOPIA_KEEP_WEEKLY="${KOPIA_KEEP_WEEKLY:-4}"
KOPIA_KEEP_MONTHLY="${KOPIA_KEEP_MONTHLY:-12}"

echo "[1/6] install kopia + prometheus-node-exporter + jq (idempotent)"
export DEBIAN_FRONTEND=noninteractive
# Force IPv4 for apt: dock hosts have working IPv4 outbound but DNS for the
# canonical mirror returns AAAA-only on this network, which makes apt sit in
# SYN_SENT for ~75s per fetch before the kernel times out. The first
# kopia-backup.sh roll-out on docker-1/docker-2 spent 5+ min stuck on the
# prometheus-node-exporter download for exactly this reason.
if [[ ! -f /etc/apt/apt.conf.d/99force-ipv4 ]]; then
  echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
fi
if ! command -v kopia >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://kopia.io/signing-key | gpg --dearmor -o /etc/apt/keyrings/kopia-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main" \
    > /etc/apt/sources.list.d/kopia.list
  apt-get update
  apt-get install -y kopia
fi
# node_exporter for textfile-collector kopia metrics. Listens on :9100 — scraped
# by the in-cluster Prometheus via additionalScrapeConfigs (job dock-hosts).
apt-get install -y --no-install-recommends prometheus-node-exporter jq

# Textfile collector dir (writable by root only — same identity that runs the
# kopia service). Drop-in adds the flag to the Ubuntu-packaged systemd unit.
install -d -m 0755 /var/lib/node_exporter/textfile_collector
install -d -m 0755 /etc/systemd/system/prometheus-node-exporter.service.d
cat > /etc/systemd/system/prometheus-node-exporter.service.d/10-textfile.conf <<'EOF'
[Service]
# Override the unit's ExecStart so our textfile-collector flag is honored
# regardless of /etc/default/prometheus-node-exporter ARGS.
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
EOF
systemctl daemon-reload
systemctl enable --now prometheus-node-exporter.service
systemctl restart prometheus-node-exporter.service

echo "[2/6] write /etc/kopia/env (mode 0600)"
install -d -m 0700 /etc/kopia
umask 0177
cat > /etc/kopia/env <<EOF
# Managed by kopia-backup.sh — re-run script to regenerate.
# KOPIA_CONFIG_PATH is set explicitly because systemd does not export HOME for
# root services, and kopia's default config-path lookup relies on \$HOME.
KOPIA_CONFIG_PATH=/root/.config/kopia/repository.config
KOPIA_S3_BUCKET=${KOPIA_S3_BUCKET}
KOPIA_S3_ENDPOINT=${KOPIA_S3_ENDPOINT}
KOPIA_S3_REGION=${KOPIA_S3_REGION}
KOPIA_S3_PREFIX=${KOPIA_S3_PREFIX}
KOPIA_S3_ACCESS_KEY=${KOPIA_S3_ACCESS_KEY}
KOPIA_S3_SECRET_KEY=${KOPIA_S3_SECRET_KEY}
KOPIA_PASSWORD=${KOPIA_PASSWORD}
EOF
umask 0022
chmod 0600 /etc/kopia/env

echo "[3/6] write /etc/kopia/sources.list (operator-editable)"
if [[ ! -f /etc/kopia/sources.list ]]; then
  : > /etc/kopia/sources.list
  for p in ${KOPIA_PATHS}; do
    echo "$p" >> /etc/kopia/sources.list
  done
fi
chmod 0644 /etc/kopia/sources.list

echo "[4/6] connect or create kopia repo at s3://${KOPIA_S3_BUCKET}/${KOPIA_S3_PREFIX}"
KOPIA_CONFIG_PATH=/root/.config/kopia/repository.config
if [[ ! -f "${KOPIA_CONFIG_PATH}" ]]; then
  set +e
  KOPIA_ERR="$(mktemp)"
  kopia repository connect s3 \
    --bucket="${KOPIA_S3_BUCKET}" \
    --endpoint="${KOPIA_S3_ENDPOINT}" \
    --region="${KOPIA_S3_REGION}" \
    --prefix="${KOPIA_S3_PREFIX}" \
    --access-key="${KOPIA_S3_ACCESS_KEY}" \
    --secret-access-key="${KOPIA_S3_SECRET_KEY}" \
    --password="${KOPIA_PASSWORD}" 2>"${KOPIA_ERR}"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qiE "not initialized|repository not found|NoSuchKey" "${KOPIA_ERR}"; then
      echo "    no existing repo — initializing new one"
      kopia repository create s3 \
        --bucket="${KOPIA_S3_BUCKET}" \
        --endpoint="${KOPIA_S3_ENDPOINT}" \
        --region="${KOPIA_S3_REGION}" \
        --prefix="${KOPIA_S3_PREFIX}" \
        --access-key="${KOPIA_S3_ACCESS_KEY}" \
        --secret-access-key="${KOPIA_S3_SECRET_KEY}" \
        --password="${KOPIA_PASSWORD}"
    else
      cat "${KOPIA_ERR}" >&2
      rm -f "${KOPIA_ERR}"
      exit 1
    fi
  fi
  rm -f "${KOPIA_ERR}"
fi

echo "[5/6] set retention policy (global)"
KOPIA_PASSWORD="${KOPIA_PASSWORD}" kopia policy set --global \
  --keep-latest=10 \
  --keep-hourly=0 \
  --keep-daily="${KOPIA_KEEP_DAILY}" \
  --keep-weekly="${KOPIA_KEEP_WEEKLY}" \
  --keep-monthly="${KOPIA_KEEP_MONTHLY}" \
  --keep-annual=0

echo "[6/6] install runner + systemd service/timer"
cat > /usr/local/bin/kopia-backup-run.sh <<'RUNSH'
#!/usr/bin/env bash
# Snapshot every path in /etc/kopia/sources.list, run maintenance, then write
# Prometheus metrics to a textfile for the node_exporter textfile collector.
# Invoked by kopia-backup.service. Metrics are atomic — they are written to
# .tmp and renamed at the end, so node_exporter never sees a partial file.
set -euo pipefail
# shellcheck disable=SC1091
source /etc/kopia/env
export KOPIA_PASSWORD KOPIA_CONFIG_PATH

METRICS_DIR=/var/lib/node_exporter/textfile_collector
METRICS_FILE="${METRICS_DIR}/kopia.prom"
METRICS_TMP="${METRICS_FILE}.$$"
mkdir -p "${METRICS_DIR}"

run_start=$(date +%s)

mapfile -t paths < <(grep -vE '^\s*(#|$)' /etc/kopia/sources.list || true)
if [[ ${#paths[@]} -eq 0 ]]; then
  echo "no paths in /etc/kopia/sources.list — nothing to do" >&2
  exit 0
fi

# Per-source results captured for metrics emission at the end. Indexed by
# source path. Bash assoc arrays — fine on bash 4+.
declare -A status_by_src duration_by_src size_by_src files_by_src
failed=0

for p in "${paths[@]}"; do
  if [[ ! -d "$p" ]]; then
    echo "skip $p (not a directory)"
    continue
  fi
  echo "snapshotting $p"
  src_start=$(date +%s)
  if kopia snapshot create "$p"; then
    src_end=$(date +%s)
    status_by_src["$p"]=1
    duration_by_src["$p"]=$((src_end - src_start))
    # Pull size + file count from the latest snapshot of this source.
    snap_json=$(kopia snapshot list --json --max-results=1 "$p" 2>/dev/null || echo '[]')
    size_by_src["$p"]=$(echo "$snap_json" | jq -r '.[0].rootEntry.summ.size // .[0].stats.totalSize // 0' 2>/dev/null || echo 0)
    files_by_src["$p"]=$(echo "$snap_json" | jq -r '.[0].rootEntry.summ.files // .[0].stats.totalFileCount // 0' 2>/dev/null || echo 0)
  else
    src_end=$(date +%s)
    echo "ERROR: snapshot of $p failed" >&2
    status_by_src["$p"]=0
    duration_by_src["$p"]=$((src_end - src_start))
    size_by_src["$p"]=0
    files_by_src["$p"]=0
    failed=1
  fi
done

echo "running maintenance"
kopia maintenance run --safety=full || true

# Repo size: total bytes of all blobs in S3 (actual storage charge),
# extracted from `kopia blob stats --raw`. There is no JSON form for this
# subcommand; the human output is stable: lines starting with "Total:".
repo_size=$(kopia blob stats --raw 2>/dev/null \
  | awk '/^Total:/{print $2; exit}' || echo 0)
repo_size=${repo_size:-0}

run_end=$(date +%s)
run_duration=$((run_end - run_start))

# Compose the textfile. Ordered so HELP/TYPE precede every sample series.
{
  echo "# HELP kopia_backup_run_timestamp_seconds Unix timestamp when the kopia backup run finished"
  echo "# TYPE kopia_backup_run_timestamp_seconds gauge"
  echo "kopia_backup_run_timestamp_seconds ${run_end}"
  echo "# HELP kopia_backup_run_duration_seconds Total duration of the kopia backup run, including maintenance"
  echo "# TYPE kopia_backup_run_duration_seconds gauge"
  echo "kopia_backup_run_duration_seconds ${run_duration}"
  echo "# HELP kopia_backup_run_status 1 if all snapshot sources succeeded, 0 if any failed"
  echo "# TYPE kopia_backup_run_status gauge"
  if [[ ${failed} -eq 0 ]]; then echo "kopia_backup_run_status 1"; else echo "kopia_backup_run_status 0"; fi
  echo "# HELP kopia_backup_repo_size_bytes Total used storage size of the kopia repository (post dedup/compression)"
  echo "# TYPE kopia_backup_repo_size_bytes gauge"
  echo "kopia_backup_repo_size_bytes ${repo_size}"
  echo "# HELP kopia_backup_source_status 1 if last snapshot of source succeeded, 0 if failed"
  echo "# TYPE kopia_backup_source_status gauge"
  for src in "${!status_by_src[@]}"; do
    echo "kopia_backup_source_status{source=\"${src}\"} ${status_by_src[$src]}"
  done
  echo "# HELP kopia_backup_source_duration_seconds Duration of last snapshot of source in seconds"
  echo "# TYPE kopia_backup_source_duration_seconds gauge"
  for src in "${!duration_by_src[@]}"; do
    echo "kopia_backup_source_duration_seconds{source=\"${src}\"} ${duration_by_src[$src]}"
  done
  echo "# HELP kopia_backup_source_size_bytes Logical size of last successful snapshot of source"
  echo "# TYPE kopia_backup_source_size_bytes gauge"
  for src in "${!size_by_src[@]}"; do
    echo "kopia_backup_source_size_bytes{source=\"${src}\"} ${size_by_src[$src]}"
  done
  echo "# HELP kopia_backup_source_files Number of files in last successful snapshot of source"
  echo "# TYPE kopia_backup_source_files gauge"
  for src in "${!files_by_src[@]}"; do
    echo "kopia_backup_source_files{source=\"${src}\"} ${files_by_src[$src]}"
  done
} > "${METRICS_TMP}"
chmod 0644 "${METRICS_TMP}"
mv "${METRICS_TMP}" "${METRICS_FILE}"

exit ${failed}
RUNSH
chmod 0755 /usr/local/bin/kopia-backup-run.sh

cat > /etc/systemd/system/kopia-backup.service <<EOF
[Unit]
Description=Kopia snapshot of docker volumes and stack configs
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/kopia/env
ExecStart=/usr/local/bin/kopia-backup-run.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

cat > /etc/systemd/system/kopia-backup.timer <<EOF
[Unit]
Description=Daily Kopia backup of docker host

[Timer]
OnCalendar=*-*-* ${KOPIA_DAILY_AT}:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now kopia-backup.timer

echo
echo "==== kopia-backup.sh complete ===="
echo "Repository: s3://${KOPIA_S3_BUCKET}/${KOPIA_S3_PREFIX}"
echo "Sources:    /etc/kopia/sources.list"
echo
echo "Verify now:    sudo systemctl start kopia-backup.service"
echo "Tail run:      sudo journalctl -u kopia-backup.service -f"
echo "Next fire:     systemctl list-timers kopia-backup.timer"
echo "List snaps:    sudo kopia snapshot list"
