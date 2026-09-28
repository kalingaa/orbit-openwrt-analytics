# Manual device names

Device aliases are stored on OpenWrt in `/etc/prometheus-device-names` and are
matched by MAC address. Changing an alias clears the collector cache, so Grafana
usually shows the new name after the next five-second detailed scrape.

```sh
ssh root@ROUTER_ADDRESS

device-name set 02:00:00:00:00:01 "Living Room TV"
device-name list
device-name remove 02:00:00:00:00:01
```

Names can contain spaces. A MAC address can have only one manual alias.
