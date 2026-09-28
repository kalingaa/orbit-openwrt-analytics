# Security policy

Please report vulnerabilities privately to the repository maintainers instead
of opening a public issue. Include a minimal reproduction without credentials
or real household/business traffic data.

The exporter, Prometheus, and Grafana should not be exposed directly to the
Internet. Restrict them to a trusted LAN, management VLAN, VPN, or authenticated
reverse proxy. Use SSH keys and change Grafana's initial administrator password.
