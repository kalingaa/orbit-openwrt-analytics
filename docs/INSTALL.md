# Installation and operations

## 1. Configure

Copy `config.example` to `config.env`. Configure one to three comma-separated
WAN network names and matching Linux device names. For PPPoE, the device is
usually `pppoe-wan`; verify with `ubus call network.interface dump` and
`ip link`. WAN names must match OpenWrt network/mwan3 section names.

Do not put SSH or Grafana passwords in `config.env`. The installer uses normal
SSH key or interactive authentication.

## 2. Preflight and render

```sh
./manage.sh check
./manage.sh render
./manage.sh test
```

`check` validates local tools and connectivity without changing either host.
`render` writes site-specific files to `build/`. `test` parses dashboards and
checks that no template tokens or private sample values remain.

## 3. Install or upgrade

```sh
./manage.sh install
```

The router phase installs required packages, copies collectors and passive
nftables includes, validates `fw4`, and restarts the affected services. The
server phase installs Prometheus, node exporter, and Grafana if needed, then
provisions rules, datasource, and dashboards. Existing managed files are copied
to a timestamped backup directory before replacement.

The router dependencies include `socat`. The
`prometheus-netify-stream` procd service uses it to consume Netify's local Unix
socket continuously; no Netify metadata is sent to an external cloud service.
The stream writes compact counter state every five seconds and the installer
adds a five-minute passive-DPI memory guard for embedded-router safety.

Router transfers use legacy SCP mode because Dropbear installations do not
normally ship an SFTP server. During upgrades, the installer also migrates the
legacy WAN-device include name and safely recreates its generated dynamic
meters before reloading the validated firewall ruleset.
It also removes the former `90-prometheus-wan-apps.nft` filename after backing
it up; retaining it alongside the current include would count every packet
twice.

When Grafana is not already available through APT, the installer configures the
[official Grafana stable repository](https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/)
and installs the OSS `grafana` package.

Run `./manage.sh install-router` or `./manage.sh install-server` to deploy one
side only. Re-run the same commands to upgrade.

## 4. Operate

```sh
./manage.sh status
./manage.sh backup
```

`status` checks services, HTTP readiness, and Prometheus targets. `backup`
collects configuration and the Grafana database into `backups/`; it does not
copy the full Prometheus TSDB. Use a stopped-service filesystem or VM snapshot
for a consistent TSDB backup.

Friendly device names are managed on OpenWrt:

```sh
device-name set 02:00:00:00:00:01 "Living Room TV"
device-name list
device-name remove 02:00:00:00:00:01
```

## 5. Remove

```sh
./manage.sh uninstall
```

The command disables project services/configuration and removes only files
owned by this project after creating a backup. It does not delete Prometheus
history, Grafana's database, or packages unless `--purge-data` is explicitly
provided. Review the printed target paths before confirming.

## Network security

Allow the analytics server to reach the router exporter port on the trusted
LAN. Do not forward Grafana, Prometheus, or exporter ports from the Internet.
For remote access, use a VPN or an authenticated TLS reverse proxy.
