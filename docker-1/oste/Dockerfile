# OSTE-Meta-Scan packaged as a Kali browser-desktop. The upstream OSTE is
# a Tkinter GUI app (no web UI), so we wrap it in kasmweb's
# kali-rolling-desktop (Kali Linux + KasmVNC + XFCE) and pre-install the
# scanner toolchain (ZAP / Wapiti / Skipfish / Nikto / Nuclei) plus OSTE
# itself.
#
# Browser → :6901 HTTPS (KasmVNC self-signed) → desktop → menu →
# OSTE Meta Scan. Traefik bundle (clusters/default/legacy-vm.yaml) uses
# scheme: https + serversTransport: lan-self-signed to skip cert verify.
#
# Build context: docker-1/legacy-vm/  (Komodo runs `docker compose up -d` here).
FROM kasmweb/kali-rolling-desktop:1.19.0@sha256:670b855a8b0670ada0ce5e0c997c492fcb66fdf1ca2ef4dffc157bffe2395544

USER root

# Kali repos already have all of these.
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
        nuclei \
    && rm -rf /var/lib/apt/lists/*

# OSTE source.
RUN git clone --depth=1 https://github.com/OSTEsayed/OSTE-Meta-Scan.git /opt/legacy-vm \
    && chown -R 1000:1000 /opt/legacy-vm

# Python deps.
RUN pip3 install --no-cache-dir --break-system-packages \
        -r /opt/legacy-vm/OSTEscaner/requirements.txt

# Desktop shortcut.
RUN cat > /usr/share/applications/legacy-vm-meta-scan.desktop <<'EOF'
[Desktop Entry]
Name=OSTE Meta Scan
Comment=Web vulnerability meta-scanner (ZAP / Wapiti / Skipfish / Nikto / Nuclei)
Exec=python3 /opt/legacy-vm/OSTEscaner/Metascan.py
Icon=/opt/legacy-vm/OSTEscaner/images/meta.png
Terminal=true
Type=Application
Categories=Security;
EOF

USER 1000
