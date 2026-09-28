local json = require "cjson"

local snapshot_path = rawget(_G, "NETIFY_SNAPSHOT_PATH") or "/var/run/netifyd/sink-request.json"
local state_path = rawget(_G, "NETIFY_STATE_PATH") or "/tmp/prometheus-netify-state.json"
local stream_state_path = rawget(_G, "NETIFY_STREAM_STATE_PATH") or
  "/tmp/prometheus-netify-stream-state.json"

local function safe(value)
  if value == nil or value == json.null then return "" end
  return tostring(value):gsub('["\\\r\n\t]', '_')
end

local function read_json(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local raw = file:read("*a")
  file:close()
  local ok, value = pcall(json.decode, raw)
  if ok and type(value) == "table" then return value end
  return nil
end

local function write_json(path, value)
  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then return false end
  local ok, encoded = pcall(json.encode, value)
  if not ok then file:close(); os.remove(tmp); return false end
  file:write(encoded)
  file:close()
  return os.rename(tmp, path)
end

local function load_names()
  local names = {}
  local cache = io.open("/tmp/prometheus-device-names.cache", "r")
  if cache then
    cache:read("*l")
    for line in cache:lines() do
      local mac, name = line:match("^([^\t]+)\t(.*)$")
      if mac and name then names[string.upper(mac)] = safe(name) end
    end
    cache:close()
  end

  local aliases = io.open("/etc/prometheus-device-names", "r")
  if aliases then
    for line in aliases:lines() do
      local mac, name = line:match("^%s*([%x:]+)%s+(.+)%s*$")
      if mac and name and line:sub(1, 1) ~= "#" then
        names[string.upper(mac)] = safe(name)
      end
    end
    aliases:close()
  end
  return names
end

local function tuple_key(proto, src, sport, dst, dport)
  return table.concat({proto or "", src or "", sport or "", dst or "", dport or ""}, "|")
end

local function load_wan_map()
  local tuples = {}
  local pipe = io.popen("conntrack -L -o extended 2>/dev/null")
  if not pipe then return tuples end
  for line in pipe:lines() do
    local proto = line:match("^%S+%s+%d+%s+(%S+)") or ""
    local mark = tonumber(line:match("mark=(%d+)")) or 0
    local index = math.floor(mark / 256) % 256
    local wan = (index >= 1 and index <= 3) and ("WAN" .. index) or "unknown"
    for src, dst, sport, dport in line:gmatch("src=(%S+)%s+dst=(%S+)%s+sport=(%d+)%s+dport=(%d+)") do
      tuples[tuple_key(proto, src, sport, dst, dport)] = wan
    end
  end
  pipe:close()
  return tuples
end

local service_domains = {
  {"googlevideo.com", "YouTube"}, {"youtube.com", "YouTube"},
  {"ytimg.com", "YouTube"}, {"youtu.be", "YouTube"},
  {"netflix.com", "Netflix"}, {"nflxvideo.net", "Netflix"},
  {"nflximg.net", "Netflix"}, {"spotify.com", "Spotify"},
  {"scdn.co", "Spotify"}, {"tiktok.com", "TikTok"},
  {"tiktokcdn.com", "TikTok"}, {"byteoversea.com", "TikTok"},
  {"instagram.com", "Instagram"}, {"cdninstagram.com", "Instagram"},
  {"whatsapp.com", "WhatsApp"}, {"whatsapp.net", "WhatsApp"},
  {"facebook.com", "Facebook"}, {"fbcdn.net", "Facebook"},
  {"messenger.com", "Facebook Messenger"}, {"discord.com", "Discord"},
  {"discordapp.com", "Discord"}, {"discordapp.net", "Discord"},
  {"telegram.org", "Telegram"}, {"t.me", "Telegram"},
  {"signal.org", "Signal"}, {"zoom.us", "Zoom"},
  {"reddit.com", "Reddit"}, {"redd.it", "Reddit"},
  {"twitter.com", "X / Twitter"}, {"twimg.com", "X / Twitter"},
  {"x.com", "X / Twitter"}, {"icloud.com", "Apple iCloud"},
  {"apple.com", "Apple"}, {"mzstatic.com", "Apple"},
  {"microsoft.com", "Microsoft"}, {"microsoftonline.com", "Microsoft 365"},
  {"office.com", "Microsoft 365"}, {"office365.com", "Microsoft 365"},
  {"live.com", "Microsoft"}, {"github.com", "GitHub"},
  {"githubusercontent.com", "GitHub"}, {"dropbox.com", "Dropbox"},
  {"amazon.com", "Amazon"}, {"amazonaws.com", "Amazon Web Services"},
  {"cloudfront.net", "Amazon CloudFront"}, {"cloudflare.com", "Cloudflare"},
  {"cloudflare-dns.com", "Cloudflare DNS"}, {"dns.google", "Google DNS"},
  {"dns.quad9.net", "Quad9 DNS"}, {"dns.nextdns.io", "NextDNS"},
  {"dns.adguard-dns.com", "AdGuard DNS"}, {"dns.controld.com", "Control D DNS"}
}

local multi_part_suffixes = {
  ["co.uk"] = true, ["org.uk"] = true, ["com.au"] = true,
  ["net.au"] = true, ["co.nz"] = true, ["co.jp"] = true,
  ["com.br"] = true, ["com.sg"] = true, ["com.lk"] = true
}

local function nonempty(value)
  value = safe(value)
  if value == "" or value == "Unknown" or value == "unknown" then return nil end
  return value
end

local function detected_hostname(flow)
  local hostname = nonempty(flow.detected_hostname) or nonempty(flow.host_server_name) or
    nonempty(flow.dns_host_name)
  if not hostname and type(flow.ssl) == "table" then
    hostname = nonempty(flow.ssl.client_sni) or nonempty(flow.ssl.server_name)
  end
  if not hostname then return "Unknown" end
  hostname = hostname:lower():gsub("%.$", "")
  if hostname:match("^%d+%.%d+%.%d+%.%d+$") or #hostname > 253 then return "Unknown" end
  return hostname
end

local function base_domain(hostname)
  if hostname == "Unknown" then return hostname end
  local parts = {}
  for part in hostname:gmatch("[^%.]+") do parts[#parts + 1] = part end
  if #parts < 3 then return hostname end
  local suffix = parts[#parts - 1] .. "." .. parts[#parts]
  if multi_part_suffixes[suffix] and #parts >= 3 then
    return parts[#parts - 2] .. "." .. suffix
  end
  return suffix
end

local function contains_any(value, terms)
  value = (value or ""):lower()
  for _, term in ipairs(terms) do
    if value:find(term, 1, true) then return true end
  end
  return false
end

local function intelligence(flow)
  local found = {}
  if type(flow.intel) == "table" then
    for _, item in ipairs(flow.intel) do
      if type(item) == "table" then
        local value = nonempty(item.indicator) or nonempty(item.indicator_driver) or
          nonempty(item.data_feed) or nonempty(item.category)
        if value then found[#found + 1] = value:lower() end
      end
    end
  end
  return table.concat(found, ",")
end

local function service_from_domain(domain)
  if domain == "Unknown" then return nil end
  for _, entry in ipairs(service_domains) do
    local suffix = entry[1]
    if domain == suffix or domain:sub(-(suffix:len() + 1)) == "." .. suffix then
      return entry[2]
    end
  end
  return nil
end

local function classify(flow)
  local raw_app = nonempty(flow.detected_application_name)
  local dpi_application = raw_app and raw_app:gsub("^netify%.", "") or "Unknown"
  local protocol = nonempty(flow.detected_protocol_name) or "Unknown"
  local hostname = detected_hostname(flow)
  local domain = base_domain(hostname)
  local service = raw_app and dpi_application or service_from_domain(domain) or domain
  if not service or service == "Unknown" then service = "Unknown" end
  local application = service ~= "Unknown" and service or dpi_application

  local intel = intelligence(flow)
  local evidence = table.concat({dpi_application, protocol, service, domain, intel}, " "):lower()
  local protocol_key = protocol:lower()
  local traffic_class = "application"
  local detection = raw_app and "dpi" or (domain ~= "Unknown" and "hostname" or "protocol")

  if contains_any(evidence, {"tor_relay", "tor-exit", " tor", "tor "}) then
    traffic_class = "tor"
  elseif protocol_key == "doh" or protocol_key == "dot" or protocol_key == "doq" or
      contains_any(evidence, {"dns-over-https", "dns over https", "dns-over-tls",
      "dns over tls", "dns-over-quic", "dns over quic", "cloudflare dns",
      "google dns", "quad9 dns", "nextdns", "adguard dns", "control d dns"}) or
      tonumber(flow.other_port) == 853 then
    traffic_class = "encrypted_dns"
  elseif contains_any(evidence, {"vpn", "wireguard", "openvpn", "tailscale", "zerotier",
      "ipsec", "nordvpn", "protonvpn", "expressvpn", "surfshark", "tunnel"}) then
    traffic_class = "vpn"
  elseif contains_any(evidence, {"proxy", "socks", "privacy-relay", "private relay"}) then
    traffic_class = "proxy"
  elseif dpi_application == "Unknown" then
    traffic_class = protocol:lower():find("quic", 1, true) and "unresolved_quic" or "unclassified"
  end

  if intel ~= "" then detection = "intelligence" end
  return application, dpi_application, protocol, service, domain, traffic_class, detection,
    (intel ~= "" and intel or "none")
end

local function totals_key(labels)
  return table.concat({labels.application, labels.dpi_application, labels.protocol,
    labels.service, labels.domain, labels.traffic_class, labels.detection,
    labels.intelligence, labels.wan, labels.ip, labels.mac, labels.device_name}, "\t")
end

local function migrate_state(state)
  if state.version == 3 then return state end
  if state.version ~= 2 then return {version = 3, seen = {}, totals = {}} end

  local migrated = {version = 3, seen = state.seen or {}, totals = {}}
  for _, total in pairs(state.totals or {}) do
    local labels = total.labels or {}
    labels.dpi_application = labels.application or "Unknown"
    if labels.service and labels.service ~= "Unknown" then labels.application = labels.service end
    local key = totals_key(labels)
    local existing = migrated.totals[key] or
      {labels = labels, upload = 0, download = 0, flows = 0}
    existing.upload = (existing.upload or 0) + (total.upload or 0)
    existing.download = (existing.download or 0) + (total.download or 0)
    existing.flows = (existing.flows or 0) + (total.flows or 0)
    migrated.totals[key] = existing
  end
  return migrated
end

local function scrape()
  local bytes_metric = metric("openwrt_netify_application_bytes_total", "counter")
  local flows_metric = metric("openwrt_netify_application_flows_total", "counter")
  local active_metric = metric("openwrt_netify_active_flows", "gauge")
  local classified_metric = metric("openwrt_netify_classified_ratio", "gauge")
  local service_metric = metric("openwrt_netify_service_classified_ratio", "gauge")
  local hostname_metric = metric("openwrt_netify_hostname_visibility_ratio", "gauge")
  local stream_metric = metric("openwrt_netify_stream_up", "gauge")
  local stream_events_metric = metric("openwrt_netify_stream_events_total", "counter")
  local stream_unmatched_metric = metric("openwrt_netify_stream_unmatched_events_total", "counter")
  local stream_duplicate_metric = metric("openwrt_netify_stream_duplicate_events_total", "counter")

  local now = os.time()
  local stream_state = read_json(stream_state_path)
  local stream_fresh = stream_state and stream_state.version == 1 and
    now - (tonumber(stream_state.updated_at) or 0) <= 60
  stream_metric({}, stream_fresh and 1 or 0)
  stream_events_metric({}, stream_state and (stream_state.events_total or 0) or 0)
  stream_unmatched_metric({}, stream_state and (stream_state.unmatched_events_total or 0) or 0)
  stream_duplicate_metric({}, stream_state and (stream_state.duplicate_events_total or 0) or 0)
  local snapshot = read_json(snapshot_path)
  if (not snapshot or type(snapshot.flows) ~= "table") and not stream_fresh then
    active_metric({}, 0)
    classified_metric({}, 0)
    service_metric({}, 0)
    hostname_metric({}, 0)
    return
  end

  local state = stream_fresh and stream_state or
    migrate_state(read_json(state_path) or {version = 3, seen = {}, totals = {}})
  state.seen = state.seen or {}
  state.totals = state.totals or {}

  local names = load_names()
  local wan_map = load_wan_map()
  local active = 0
  local classified = 0
  local service_classified = 0
  local hostname_visible = 0
  local unique_flows = {}

  -- Netify v4 can group the same flow under bridge and physical capture
  -- interfaces. Select the copy with the largest observed byte total.
  for _, interface_flows in pairs((snapshot and snapshot.flows) or {}) do
    if type(interface_flows) == "table" then
      for _, flow in ipairs(interface_flows) do
        local digest = safe(flow.digest)
        if digest ~= "" then
          local previous = unique_flows[digest]
          local total = (tonumber(flow.local_bytes) or 0) + (tonumber(flow.other_bytes) or 0)
          local previous_total = previous and
            ((tonumber(previous.local_bytes) or 0) + (tonumber(previous.other_bytes) or 0)) or -1
          if total > previous_total then unique_flows[digest] = flow end
        end
      end
    end
  end

  for _, flow in pairs(unique_flows) do
    local ip = safe(flow.local_ip)
    local mac = string.lower(safe(flow.local_mac))
    local digest = safe(flow.digest)
    local proto_number = tonumber(flow.ip_protocol) or 0
    if ip ~= "" and mac ~= "" and digest ~= "" and (proto_number == 6 or proto_number == 17) then
      active = active + 1
      local app, dpi_app, protocol, service, domain, traffic_class, detection, intel = classify(flow)
      if safe(flow.detected_application_name) ~= "" and safe(flow.detected_application_name) ~= "Unknown" then
        classified = classified + 1
      end
      if service ~= "Unknown" then service_classified = service_classified + 1 end
      if domain ~= "Unknown" then hostname_visible = hostname_visible + 1 end

      local transport = proto_number == 6 and "tcp" or "udp"
      local wan = wan_map[tuple_key(transport, ip, flow.local_port, safe(flow.other_ip), flow.other_port)] or "unknown"
      local name = names[string.upper(mac)] or "unknown"
      local labels = {
        application = app,
        dpi_application = dpi_app,
        protocol = protocol,
        service = service,
        domain = domain,
        traffic_class = traffic_class,
        detection = detection,
        intelligence = intel,
        wan = wan,
        ip = ip,
        mac = mac,
        device_name = name
      }
      if not stream_fresh then
        local label_key = totals_key(labels)
        local previous = state.seen[digest]
        local up = tonumber(flow.local_bytes) or 0
        local down = tonumber(flow.other_bytes) or 0
        local up_delta = up
        local down_delta = down
        local is_new = 1
        if previous then
          up_delta = up >= (previous.up or 0) and (up - (previous.up or 0)) or up
          down_delta = down >= (previous.down or 0) and (down - (previous.down or 0)) or down
          is_new = 0
        end

        local total = state.totals[label_key] or {labels = labels, upload = 0, download = 0, flows = 0}
        total.labels = labels
        total.upload = (total.upload or 0) + up_delta
        total.download = (total.download or 0) + down_delta
        total.flows = (total.flows or 0) + is_new
        state.totals[label_key] = total
        state.seen[digest] = {up = up, down = down, touched = now}
      end
    end
  end

  for digest, previous in pairs(state.seen) do
    if now - (previous.touched or 0) > 3600 then state.seen[digest] = nil end
  end

  for _, total in pairs(state.totals) do
    local base = total.labels
    local upload_labels = {
      application = base.application, dpi_application = base.dpi_application,
      protocol = base.protocol, wan = base.wan,
      service = base.service, domain = base.domain, traffic_class = base.traffic_class,
      detection = base.detection, intelligence = base.intelligence,
      ip = base.ip, mac = base.mac, device_name = base.device_name, direction = "upload"
    }
    local download_labels = {
      application = base.application, dpi_application = base.dpi_application,
      protocol = base.protocol, wan = base.wan,
      service = base.service, domain = base.domain, traffic_class = base.traffic_class,
      detection = base.detection, intelligence = base.intelligence,
      ip = base.ip, mac = base.mac, device_name = base.device_name, direction = "download"
    }
    bytes_metric(upload_labels, total.upload or 0)
    bytes_metric(download_labels, total.download or 0)
    flows_metric(base, total.flows or 0)
  end

  active_metric({}, active)
  classified_metric({}, active > 0 and classified / active or 0)
  service_metric({}, active > 0 and service_classified / active or 0)
  hostname_metric({}, active > 0 and hostname_visible / active or 0)
  if not stream_fresh then write_json(state_path, state) end
end

return {
  scrape = scrape,
  safe = safe,
  read_json = read_json,
  write_json = write_json,
  load_names = load_names,
  load_wan_map = load_wan_map,
  tuple_key = tuple_key,
  classify = classify,
  totals_key = totals_key
}
