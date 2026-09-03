#!/usr/bin/env bash
# Push version-controlled Wazuh rules + active-response scripts into the running
# manager container, then restart it.
#
# /var/ossec/etc and /var/ossec/active-response/bin are Docker NAMED VOLUMES, not
# bind mounts, so the repo cannot be mounted directly without restructuring the
# compose stack. `docker cp` into the running container writes through to the
# volume and survives restarts.
#
# Run on docker-1:  ./sync-rules.sh
set -euo pipefail

MANAGER=single-node-wazuh.manager-1
HERE="$(cd "$(dirname "$0")" && pwd)"

docker inspect "$MANAGER" >/dev/null 2>&1 || { echo "container $MANAGER not found"; exit 1; }

echo "--- rules ---"
for f in "$HERE"/rules/*.xml; do
  n=$(basename "$f")
  docker cp "$f" "$MANAGER:/var/ossec/etc/rules/$n"
  docker exec "$MANAGER" chown wazuh:wazuh "/var/ossec/etc/rules/$n"
  docker exec "$MANAGER" chmod 660 "/var/ossec/etc/rules/$n"
  echo "  synced $n"
done

echo "--- active-response ---"
for f in "$HERE"/active-response/*; do
  [ -f "$f" ] || continue
  n=$(basename "$f")
  docker cp "$f" "$MANAGER:/var/ossec/active-response/bin/$n"
  docker exec "$MANAGER" chown root:wazuh "/var/ossec/active-response/bin/$n"
  docker exec "$MANAGER" chmod 750 "/var/ossec/active-response/bin/$n"
  echo "  synced $n"
done

# Validate BEFORE restarting: a malformed rule file stops the manager from
# starting at all, and a stopped manager means no detection on 22 agents.
echo "--- validating config ---"
if ! docker exec "$MANAGER" /var/ossec/bin/wazuh-logtest -t >/dev/null 2>&1; then
  echo "  WARNING: wazuh-logtest reported a problem. NOT restarting."
  echo "  Inspect with: docker exec $MANAGER /var/ossec/bin/wazuh-logtest -t"
  exit 1
fi
echo "  config OK"

echo "--- restarting manager ---"
docker restart "$MANAGER" >/dev/null
sleep 8
docker exec "$MANAGER" /var/ossec/bin/agent_control -l 2>/dev/null | grep -c '^   ID:' \
  | sed 's/^/  agents reporting: /'
