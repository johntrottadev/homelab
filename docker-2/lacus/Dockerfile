# Vendored from app-vm-project/lacus@main (docker-compose.yml + Dockerfile)
# 2026-05-04. Lacus = capture system that AIL pushes URL fetch jobs to over
# its HTTP API on :7100. Builds Valkey + Lacus + Playwright/Chromium into a
# single image. First build is heavy (~15 min, downloads chromium ~500 MB).
#
# Komodo poll path: docker-2/lacus/compose.yaml (project_name: lacus).

FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b

# Build dependencies
RUN apt-get update && apt-get -y install build-essential curl git python3 \
    gnupg2 ca-certificates

# Add xpra.org repo (interactive headed-session capture support)
RUN curl -s https://xpra.org/gpg.asc | apt-key add - \
    && echo "deb https://xpra.org/ noble main" > /etc/apt/sources.list.d/xpra.list

RUN apt-get update && apt-get -y install xpra xvfb

RUN mkdir -p /app

WORKDIR /app

# Install Valkey (Redis-compatible KV store, used as Lacus job queue)
RUN git clone https://github.com/valkey-io/valkey.git
WORKDIR /app/valkey
RUN git checkout 8.0 && make
WORKDIR /app

# Install lacus
RUN git clone https://github.com/app-vm-project/lacus.git

RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app/lacus

RUN poetry install && poetry run playwright install-deps

RUN echo LACUS_HOME="`pwd`" >> .env

RUN poetry run update --init

RUN apt-get install -y supervisor

COPY ./supervisord/supervisord.conf /supervisord/supervisord.conf

# Slim image
RUN apt-get remove -y build-essential git && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
