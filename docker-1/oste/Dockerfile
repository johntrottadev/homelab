# OSTE-Meta-Scan packaged as a webtop desktop. The upstream OSTE is a
# Tkinter GUI app (no web UI), so we wrap it in linuxserver.io's webtop
# image (Debian XFCE + noVNC) and pre-install the scanner toolchain
# (ZAP / Wapiti / Skipfish / Nikto / Nuclei) plus OSTE itself.
#
# Browser → :3000 (noVNC HTTP) → desktop → Application Menu → OSTE.
#
# Build context: docker-1/legacy-vm/  (Komodo runs `docker compose up -d` here).
FROM lscr.io/linuxserver/webtop:debian-xfce

USER root

# Scanner toolchain that OSTE wraps.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        python3-pip \
        python3-tk \
        python3-bs4 \
        zaproxy \
        wapiti \
        skipfish \
        nikto \
    && rm -rf /var/lib/apt/lists/*

# Nuclei is provided by ProjectDiscovery as a static binary on Debian
# stable (apt nuclei lags). Pin to a recent release.
RUN cd /tmp \
    && curl -fsSLO https://github.com/projectdiscovery/nuclei/releases/download/v3.3.7/nuclei_3.3.7_linux_amd64.zip \
    && unzip -o nuclei_3.3.7_linux_amd64.zip nuclei -d /usr/local/bin \
    && chmod +x /usr/local/bin/nuclei \
    && rm /tmp/nuclei_3.3.7_linux_amd64.zip

# OSTE source — clone into the linuxserver /config tree so it persists
# in the bind-mounted volume across container restarts.
RUN git clone --depth=1 https://github.com/OSTEsayed/OSTE-Meta-Scan.git /opt/legacy-vm \
    && chown -R abc:abc /opt/legacy-vm

# Python deps for OSTE's GUI + scanner orchestration.
RUN pip3 install --no-cache-dir --break-system-packages \
        -r /opt/legacy-vm/OSTEscaner/requirements.txt

# Drop a desktop shortcut so the user finds it from XFCE's menu.
RUN install -d /usr/share/applications \
    && cat > /usr/share/applications/legacy-vm-meta-scan.desktop <<'EOF'
[Desktop Entry]
Name=OSTE Meta Scan
Comment=Web vulnerability meta-scanner (ZAP / Wapiti / Skipfish / Nikto / Nuclei)
Exec=python3 /opt/legacy-vm/OSTEscaner/Metascan.py
Icon=/opt/legacy-vm/OSTEscaner/images/meta.png
Terminal=true
Type=Application
Categories=Security;
EOF

USER abc
