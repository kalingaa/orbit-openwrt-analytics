local json = require "cjson"

local function load_devices()
  local devices = {}
  local names = {}

  local cache = io.open("/tmp/prometheus-device-names.cache", "r")
  if cache then
    cache:read("*l")
    for line in cache:lines() do
      local mac, name = line:match("^([^\t]+)\t(.*)$")
      if mac and name then names[string.upper(mac)] = name end
    end
    cache:close()
  end

  local aliases = io.open("/etc/prometheus-device-names", "r")
  if aliases then
    for line in aliases:lines() do
      local mac, name = line:match("^%s*([%x:]+)%s+(.+)%s*$")
      if mac and name and line:sub(1, 1) ~= "#" then
        names[string.upper(mac)] = name
      end
    end
    aliases:close()
  end

  local leases = io.open("/tmp/dhcp.leases", "r")
  if leases then
    for line in leases:lines() do
      local _, mac, ip, hostname = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
      if mac and ip then
        local upper_mac = string.upper(mac)
        local name = names[upper_mac]
        if not name and hostname and hostname ~= "*" then name = hostname end
        devices[ip] = {mac = string.lower(mac), name = name or "unknown"}
      end
    end
    leases:close()
  end

  local neigh = io.popen("ip -4 neigh show 2>/dev/null")
  if neigh then
    for line in neigh:lines() do
      local ip, mac = line:match("^(%S+).-[Ll][Ll][Aa][Dd][Dd][Rr]%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
      if ip and mac then
        local upper_mac = string.upper(mac)
        local existing = devices[ip]
        devices[ip] = {mac = string.lower(mac), name = names[upper_mac] or (existing and existing.name) or "unknown"}
      end
    end
    neigh:close()
  end

  return devices
end

local function scrape()
  local bytes = metric("openwrt_wan_device_bytes_total", "counter")
  local packets = metric("openwrt_wan_device_packets_total", "counter")
  local devices = load_devices()

  -- Read only our small managed sets. Listing the complete fw4 table also serializes
  -- the much larger application meters and can make a scrape unnecessarily slow.
  for _, wan in ipairs({__WAN_NAMES_LUA__}) do
    for _, direction in ipairs({"download", "upload"}) do
      local set_name = "prom_wan_device_" .. wan .. "_" .. direction
      local handle = io.popen("nft --json list set inet fw4 " .. set_name .. " 2>/dev/null")
      if handle then
        local raw = handle:read("*a")
        handle:close()
        local ok, decoded = pcall(json.decode, raw)
        if ok and decoded and decoded.nftables then
          for _, item in ipairs(decoded.nftables) do
            local set = item.set
            for _, wrapped in ipairs(set and set.elem or {}) do
              local elem = wrapped.elem or wrapped
              local ip = elem.val
              local counter = elem.counter
              if ip and counter then
                ip = tostring(ip)
                local device = devices[ip] or {mac = "unknown", name = "unknown"}
                local labels = {wan = wan, direction = direction, ip = ip, mac = device.mac, device_name = device.name}
                bytes(labels, tonumber(counter.bytes) or 0)
                packets(labels, tonumber(counter.packets) or 0)
              end
            end
          end
        end
      end
    end
  end
end

return { scrape = scrape }
