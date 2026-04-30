# PALOARP — Palo Alto ARP/DHCP discovery for NetAlertX

Pulls ARP entries (every VLAN the PA has an SVI on) and DHCP leases (for hostnames) from PAN-OS via the XML API and feeds them into NetAlertX as a device-discovery source. Modeled on the upstream `arp_scan` plugin.

## Why

NetAlertX's built-in `arp_scan` only sees the L2 segments its container can reach. The Palo Alto sees every VLAN. Wiring it in gets you a true cross-VLAN inventory.

## Palo Alto setup

1. **Admin role** — Device → Admin Roles → new role; under *XML API* enable **Operational Requests** only. Disable Web UI access.
2. **Admin user** — Device → Administrators → add user with that role. Local auth is fine.
3. **API key** — generate via:
   ```bash
   curl -k "https://<pa>/api/?type=keygen&user=<u>&password=<p>"
   ```
4. **Connectivity** — PA management interface must be reachable from the NetAlertX pod. If mgmt lives on a separate VRF/iface, allow the k3s pod CIDR.

## Env vars (read by `script.py`)

| Var | Required | Purpose |
|---|---|---|
| `PALO_HOST` | yes | PA mgmt hostname or IP |
| `PALO_API_KEY` | yes | from step 3 above |
| `PALO_VERIFY_TLS` | no | `false` to skip cert check (default `true`) |
| `PALO_IFACE_INCLUDE` | no | comma list, e.g. `ethernet1/2.10,ethernet1/2.20` — only emit ARP from these |
| `PALO_IFACE_EXCLUDE` | no | comma list — drop entries from these (e.g. mgmt, tunnels) |
| `PALO_TIMEOUT` | no | HTTP timeout seconds, default 20 |

## Output format

Pipe-delimited rows on stdout, one per discovered device:

```
mac | null | YYYY-MM-DD HH:MM:SS | ip | "" | hostname | iface | null | mac
```

Mapped to `scanMac`, `scanLastIP`, `scanVendor` (left blank — NetAlertX resolves OUI itself), and informational columns for hostname + interface (which doubles as your VLAN tag in the UI).

## Deploy

See `../k8s/` for the secret + Deployment patch needed to mount this plugin into the running NetAlertX pod.
