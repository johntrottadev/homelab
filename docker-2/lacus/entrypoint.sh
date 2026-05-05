#!/bin/bash
# Vendored from app-vm-project/lacus@main 2026-05-04. Starts the bundled Valkey
# (Lacus job queue) then hands off to supervisord, which runs the website
# (HTTP API on :7100) and capture_manager workers.
set -e
set -x

/bin/bash -c 'cd /app/lacus/cache && ./run_redis.sh'
/usr/bin/supervisord -c /supervisord/supervisord.conf
