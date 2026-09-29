# OpenWrt Network Analytics

Self-hosted per-device and multi-WAN traffic analytics for OpenWrt.
The router exports Prometheus metrics; a Debian or Ubuntu server stores them
and serves provisioned Grafana dashboards.

## Features

- Per-IP and per-MAC upload, download, bandwidth, first/last seen, and aliases.
- One to three WANs with separate authoritative forwarded upload/download totals
  and interface rates.
- Automatic names from OpenWrt host hints, DHCP leases, and optional DNS PTRs.
- Inventory, behavioral profiles, reconciliation, and data-quality dashboards.
- One-second WAN samples, five-second detail samples, and long-term rollups.
- Automatic speed units: bps, kbps, Mbps, and Gbps.
- Reproducible configuration, health checks, backups, upgrades, and uninstall.

## Quick start

Requirements:

- OpenWrt with SSH access and enough storage for the listed packages.
- A persistent Debian/Ubuntu server or VM reachable from the router LAN.
- SSH keys are recommended. Passwords are never stored by this project.
- Python 3, `ssh`, and `scp` on the machine running the installer.
- A POSIX shell: Linux, macOS, WSL, or Git Bash on Windows.

```sh
cp config.example config.env
$EDITOR config.env
./manage.sh check
./manage.sh render
./manage.sh install
./manage.sh status
```

`install` deploys the router first and then the analytics server. It is safe to
run again for upgrades. Existing destination files are backed up before they
are replaced.

Grafana is then available at `http://SERVER_ADDRESS:3000` unless the port was
changed. Prometheus is at `http://SERVER_ADDRESS:9090`.

See [docs/INSTALL.md](docs/INSTALL.md) for package support, firewall guidance,
manual installation, backups, upgrades, and removal.

## Privacy

This project records traffic-volume metadata by IP and MAC, device identity
metadata, WAN totals, and router health. It does not collect payloads, DNS
queries, hostnames visited by clients, TLS SNI, DPI results, applications, or
services. Keep Grafana and Prometheus on a trusted management network and
define an appropriate retention policy.

## Project status

The initial public release targets OpenWrt 23.05/24.10-style `fw4` systems and
Debian/Ubuntu analytics hosts. Router hardware and package feeds vary, so run
`./manage.sh check` before installation and report device-specific issues.

Licensed under the [GNU General Public License v3.0](LICENSE)
(`GPL-3.0-only`).

Current development version: **0.1.0**.
