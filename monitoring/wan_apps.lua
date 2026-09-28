local json = require "cjson"

local app_names = {
  DNS_over_TLS = "DNS-over-TLS"
}

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function uci_device(wan)
  local handle = io.popen("uci -q get network." .. wan .. ".device")
  if not handle then return "unknown" end
  local value = trim(handle:read("*a"))
  handle:close()
  if value == "" then return "unknown" end
  return value
end

local function scrape()
  local info = metric("openwrt_wan_info", "gauge")
  for _, wan in ipairs({__WAN_NAMES_LUA__}) do
    info({wan = wan, device = uci_device(wan)}, 1)
  end

  local handle = io.popen("nft --json list counters")
  if not handle then return end
  local raw = handle:read("*a")
  handle:close()

  local ok, decoded = pcall(json.decode, raw)
  if not ok or not decoded or not decoded.nftables then return end

  local bytes = metric("openwrt_wan_application_bytes_total", "counter")
  local packets = metric("openwrt_wan_application_packets_total", "counter")

  for _, item in ipairs(decoded.nftables) do
    local counter = item.counter
    if counter and counter.name then
      local wan, direction, application = counter.name:match("^prom_wan_([^_]+)_([^_]+)_(.+)$")
      if wan and (direction == "download" or direction == "upload") then
        application = app_names[application] or application
        local labels = {wan = wan, direction = direction, application = application}
        bytes(labels, tonumber(counter.bytes) or 0)
        packets(labels, tonumber(counter.packets) or 0)
      end
    end
  end
end

return { scrape = scrape }
