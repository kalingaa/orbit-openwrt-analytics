#!/usr/bin/env python3
"""Render site-specific deployment files from the tracked templates."""

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "monitoring"
BUILD = ROOT / "build"


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: expected NAME=value")
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def require(values: dict[str, str], *names: str) -> None:
    missing = [name for name in names if not values.get(name)]
    if missing:
        raise ValueError("missing required settings: " + ", ".join(missing))


def csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def lua_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def remove_disabled_panels(value):
    if isinstance(value, dict):
        result = {}
        for key, child in value.items():
            if key == "panels" and isinstance(child, list):
                result[key] = [
                    remove_disabled_panels(panel)
                    for panel in child
                    if "__DISABLED_WAN_" not in json.dumps(panel)
                ]
            else:
                result[key] = remove_disabled_panels(child)
        return result
    if isinstance(value, list):
        return [remove_disabled_panels(item) for item in value]
    return value


def main() -> int:
    config_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "config.env"
    if not config_path.exists():
        raise SystemExit(f"Configuration not found: {config_path}. Copy config.example to config.env.")
    values = load_env(config_path)
    require(
        values,
        "ROUTER_ADDRESS",
        "ROUTER_LABEL",
        "LAN_CIDR",
        "WAN_NAMES",
        "WAN_DEVICES",
        "PROMETHEUS_RETENTION_TIME",
        "PROMETHEUS_RETENTION_SIZE",
    )

    wan_names = csv(values["WAN_NAMES"])
    wan_devices = csv(values["WAN_DEVICES"])
    if not 1 <= len(wan_names) <= 3:
        raise ValueError("WAN_NAMES must contain one to three entries")
    if len(wan_names) != len(wan_devices):
        raise ValueError("WAN_NAMES and WAN_DEVICES must have the same number of entries")
    if len(set(wan_names)) != len(wan_names) or len(set(wan_devices)) != len(wan_devices):
        raise ValueError("WAN names and devices must be unique")
    if any(not re.fullmatch(r"[A-Za-z0-9-]+", name) for name in wan_names):
        raise ValueError("WAN names may contain only letters, numbers, and hyphens")
    if any(not re.fullmatch(r"[A-Za-z0-9_.:@-]+", device) for device in wan_devices):
        raise ValueError("WAN devices contain unsupported characters")
    if not re.fullmatch(r"[A-Za-z0-9_.:@-]+", values.get("LAN_DEVICE", "br-lan")):
        raise ValueError("LAN_DEVICE contains unsupported characters")

    dns_servers = csv(values.get("DNS_SERVERS", ""))
    replacements = {
        "__ROUTER_ADDRESS__": values["ROUTER_ADDRESS"],
        "__ROUTER_LABEL__": values["ROUTER_LABEL"],
        "__ROUTER_EXPORTER_PORT__": values.get("ROUTER_EXPORTER_PORT", "9100"),
        "__LAN_CIDR__": values["LAN_CIDR"],
        "__LAN_DEVICE__": values.get("LAN_DEVICE", "br-lan"),
        "__LOCAL_DOMAIN__": values.get("LOCAL_DOMAIN", "lan"),
        "__PROMETHEUS_RETENTION_TIME__": values["PROMETHEUS_RETENTION_TIME"],
        "__PROMETHEUS_RETENTION_SIZE__": values["PROMETHEUS_RETENTION_SIZE"],
        "__WAN_NAMES_LUA__": ", ".join(lua_quote(item) for item in wan_names),
        "__DNS_SERVERS_LUA__": ", ".join(lua_quote(item) for item in dns_servers),
    }
    for index in range(3):
        replacements[f"__WAN{index + 1}_NAME__"] = (
            wan_names[index] if index < len(wan_names) else f"__DISABLED_WAN_{index + 1}__"
        )
        replacements[f"__WAN{index + 1}_DEVICE__"] = (
            wan_devices[index] if index < len(wan_devices) else f"__DISABLED_WAN_{index + 1}__"
        )

    if BUILD.exists():
        shutil.rmtree(BUILD)
    shutil.copytree(SOURCE, BUILD)
    private_aliases = BUILD / "prometheus-device-names"
    if private_aliases.exists():
        private_aliases.unlink()
    (BUILD / "prometheus-device-names").write_text(
        "# Optional aliases: one MAC address and friendly name per line.\n",
        encoding="utf-8",
    )
    (BUILD / "site.env").write_text(
        "LAN_DEVICE=" + values.get("LAN_DEVICE", "br-lan") + "\n"
        + "ROUTER_EXPORTER_PORT=" + values.get("ROUTER_EXPORTER_PORT", "9100") + "\n"
        + "WAN_DEVICES='" + " ".join(wan_devices) + "'\n",
        encoding="utf-8",
        newline="\n",
    )

    text_extensions = {".json", ".yml", ".yaml", ".lua", ".nft", ".conf", ""}
    for path in BUILD.rglob("*"):
        if not path.is_file() or path.suffix not in text_extensions:
            continue
        text = path.read_text(encoding="utf-8")
        for token, replacement in replacements.items():
            text = text.replace(token, replacement)
        if path.suffix == ".nft":
            text = "\n".join(line for line in text.splitlines() if "__DISABLED_WAN_" not in line) + "\n"
        path.write_text(text, encoding="utf-8", newline="\n")

    for dashboard in BUILD.glob("*dashboard.json"):
        data = json.loads(dashboard.read_text(encoding="utf-8"))
        data = remove_disabled_panels(data)
        dashboard.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8", newline="\n")

    unresolved = []
    token_pattern = re.compile(r"__[A-Z0-9_]+__")
    for path in BUILD.rglob("*"):
        if path.is_file() and path.suffix in text_extensions:
            tokens = sorted(set(token_pattern.findall(path.read_text(encoding="utf-8"))))
            if tokens:
                unresolved.append(f"{path.relative_to(ROOT)}: {', '.join(tokens)}")
    if unresolved:
        raise ValueError("unresolved template tokens:\n" + "\n".join(unresolved))

    print(f"Rendered {BUILD} for {len(wan_names)} WAN(s).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        raise SystemExit(f"Configuration error: {error}")
