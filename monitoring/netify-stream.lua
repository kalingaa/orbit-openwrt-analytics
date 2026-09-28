local json = require "cjson"

local collector_path = arg[1] or "/usr/lib/lua/prometheus-collectors/netify.lua"
local state_path = arg[2] or "/tmp/prometheus-netify-stream-state.json"
local snapshot_path = arg[3] or "/var/run/netifyd/sink-request.json"
local collector = dofile(collector_path)

local function wan_devices()
  local result = {}
  for _, wan in ipairs({__WAN_NAMES_LUA__}) do
    local pipe = io.popen("uci -q get network." .. wan .. ".device 2>/dev/null")
    if pipe then
      local device = (pipe:read("*a") or ""):match("^%s*(.-)%s*$")
      pipe:close()
      if device ~= "" then result[device] = wan end
    end
  end
  return result
end

local function new_state()
  return {
    version = 1,
    updated_at = 0,
    events_total = 0,
    duplicate_events_total = 0,
    unmatched_events_total = 0,
    non_lan_events_total = 0,
    metadata = {},
    event_ids = {},
    totals = {}
  }
end

local state = collector.read_json(state_path)
if not state or state.version ~= 1 then state = new_state() end
state.metadata = state.metadata or {}
state.event_ids = state.event_ids or {}
state.totals = state.totals or {}
state.non_lan_events_total = state.non_lan_events_total or 0
for key, total in pairs(state.totals) do
  if not collector.is_lan_ip(total.labels and total.labels.ip) then state.totals[key] = nil end
end

local names = collector.load_names()
local device_wans = wan_devices()
local conntrack_wans = collector.load_wan_map()
local dirty = 0
local last_refresh = os.time()
local last_snapshot_refresh = 0
local metadata_ttl = 900

local function copy_metadata(flow, interface)
  return {
    digest = flow.digest,
    local_ip = flow.local_ip,
    local_mac = flow.local_mac,
    local_port = flow.local_port,
    other_ip = flow.other_ip,
    other_port = flow.other_port,
    ip_protocol = flow.ip_protocol,
    detected_application_name = flow.detected_application_name,
    detected_protocol_name = flow.detected_protocol_name,
    detected_hostname = flow.detected_hostname,
    host_server_name = flow.host_server_name,
    dns_host_name = flow.dns_host_name,
    ssl = flow.ssl,
    intel = flow.intel,
    interface = interface,
    touched = os.time(),
    purged = false
  }
end

local function refresh_snapshot_metadata(now, force)
  if not force and now - last_snapshot_refresh < 30 then return end
  local snapshot = collector.read_json(snapshot_path)
  if snapshot and type(snapshot.flows) == "table" then
    for interface, flows in pairs(snapshot.flows) do
      if type(flows) == "table" then
        for _, flow in ipairs(flows) do
          local digest = collector.safe(flow.digest)
          if digest ~= "" then
            local old = state.metadata[digest]
            local metadata = copy_metadata(flow, interface)
            local snapshot_upload = tonumber(flow.local_bytes) or 0
            local snapshot_download = tonumber(flow.other_bytes) or 0
            local snapshot_total = snapshot_upload + snapshot_download
            metadata.counted = old and old.counted or false
            metadata.purged = old and old.purged or false
            metadata.last_total = old and old.last_total or
              (snapshot_total > 0 and snapshot_total or nil)
            metadata.last_upload_ratio = old and old.last_upload_ratio or
              (snapshot_total > 0 and snapshot_upload / snapshot_total or nil)
            if not old or collector.is_lan_ip(metadata.local_ip) or
                not collector.is_lan_ip(old.local_ip) then
              state.metadata[digest] = metadata
            end
          end
        end
      end
    end
  end
  last_snapshot_refresh = now
end

local function event_id(kind, flow)
  return table.concat({kind or "", tostring(flow.last_seen_at or ""),
    tostring(flow.local_bytes or ""), tostring(flow.other_bytes or ""),
    tostring(flow.total_bytes or "")}, "|")
end

local function refresh_lookups(now)
  refresh_snapshot_metadata(now, false)
  if now - last_refresh < 300 then return end
  names = collector.load_names()
  device_wans = wan_devices()
  conntrack_wans = collector.load_wan_map()
  last_refresh = now
end


refresh_snapshot_metadata(os.time(), true)

local function add_bytes(metadata, upload, download, flow_count)
  local ip = collector.safe(metadata.local_ip)
  local mac = string.lower(collector.safe(metadata.local_mac))
  local proto_number = tonumber(metadata.ip_protocol) or 0
  if not collector.is_lan_ip(ip) then
    state.non_lan_events_total = state.non_lan_events_total + 1
    return
  end
  if ip == "" or mac == "" or (proto_number ~= 6 and proto_number ~= 17) then
    state.unmatched_events_total = (state.unmatched_events_total or 0) + 1
    return
  end

  local app, dpi_app, protocol, service, domain, traffic_class, detection, intel =
    collector.classify(metadata)
  local transport = proto_number == 6 and "tcp" or "udp"
  local wan = device_wans[collector.safe(metadata.interface)] or
    conntrack_wans[collector.tuple_key(transport, ip, metadata.local_port,
      collector.safe(metadata.other_ip), metadata.other_port)] or "unknown"
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
    device_name = names[string.upper(mac)] or "unknown"
  }
  local key = collector.totals_key(labels)
  local total = state.totals[key] or {labels = labels, upload = 0, download = 0, flows = 0}
  total.labels = labels
  total.upload = (total.upload or 0) + upload
  total.download = (total.download or 0) + download
  total.flows = (total.flows or 0) + flow_count
  state.totals[key] = total
end

local function accounting_deltas(metadata, flow)
  local directional_upload = tonumber(flow.local_bytes) or 0
  local directional_download = tonumber(flow.other_bytes) or 0
  local directional_total = directional_upload + directional_download
  if directional_total > 0 then
    metadata.last_upload_ratio = directional_upload / directional_total
  end

  local current_total = tonumber(flow.total_bytes) or 0
  if current_total <= 0 then
    return directional_upload, directional_download
  end
  local previous_total = tonumber(metadata.last_total) or 0
  local total_delta = current_total >= previous_total and
    (current_total - previous_total) or current_total
  metadata.last_total = current_total

  local upload_ratio = tonumber(metadata.last_upload_ratio)
  if not upload_ratio then
    upload_ratio = directional_total > 0 and directional_upload / directional_total or 0.5
  end
  local upload = total_delta * upload_ratio
  return upload, total_delta - upload
end

local function flush()
  state.updated_at = os.time()
  collector.write_json(state_path, state)
  dirty = 0
end

for line in io.lines() do
  local ok, message = pcall(json.decode, line)
  if ok and type(message) == "table" then
    local now = os.time()
    state.updated_at = now
    refresh_lookups(now)
    local flow = message.flow
    local kind = collector.safe(message.type)
    if type(flow) == "table" and collector.safe(flow.digest) ~= "" then
      local digest = collector.safe(flow.digest)
      if kind == "flow" then
        local old = state.metadata[digest]
        local metadata = copy_metadata(flow, message.interface or flow.interface)
        metadata.counted = old and old.counted or false
        metadata.last_total = old and old.last_total or nil
        metadata.last_upload_ratio = old and old.last_upload_ratio or nil
        if not old or collector.is_lan_ip(metadata.local_ip) or
            not collector.is_lan_ip(old.local_ip) then
          state.metadata[digest] = metadata
        end
      elseif kind == "flow_stats" or kind == "flow_purge" then
        local id = event_id(kind, flow)
        if state.event_ids[digest] == id then
          state.duplicate_events_total = (state.duplicate_events_total or 0) + 1
        else
          state.event_ids[digest] = id
          local metadata = state.metadata[digest]
          if not metadata then
            refresh_snapshot_metadata(now, true)
            metadata = state.metadata[digest]
          end
          if metadata then
            metadata.touched = now
            local upload, download = accounting_deltas(metadata, flow)
            add_bytes(metadata, upload, download, metadata.counted and 0 or 1)
            if kind == "flow_purge" then
              -- A purged flow cannot produce useful future deltas. Keeping its
              -- metadata caused hundreds of thousands of stale records to
              -- accumulate and eventually exhausted router memory.
              state.metadata[digest] = nil
              state.event_ids[digest] = nil
            else
              metadata.counted = true
            end
          else
            state.unmatched_events_total = (state.unmatched_events_total or 0) + 1
          end
        end
      end
      state.events_total = (state.events_total or 0) + 1
    end
    dirty = dirty + 1

    if dirty >= 25 then
      for digest, metadata in pairs(state.metadata) do
        if now - (metadata.touched or 0) > metadata_ttl then
          state.metadata[digest] = nil
          state.event_ids[digest] = nil
        end
      end
      flush()
    end
  end
end

if dirty > 0 then flush() end
