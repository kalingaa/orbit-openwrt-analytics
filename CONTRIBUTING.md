# Contributing

Issues and pull requests are welcome. Please include the OpenWrt release,
router architecture, analytics-host distribution, number of WANs, and relevant
sanitized logs. Never submit passwords, public IP addresses, DNS histories,
device MAC addresses, or unredacted dashboard exports.

Before submitting a change, run:

```sh
./manage.sh check
./manage.sh render
./manage.sh test
```

Keep collectors lightweight: the one-second scrape must finish in under 900 ms
and the detail scrape in under four seconds on the target router.
