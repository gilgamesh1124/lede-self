local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local m = Map("wiremesh", translate("Wired Mesh Settings"),
	translate("Configure B.A.T.M.A.N. Advanced wired mesh networking. "
		.. "Connect multiple routers via Ethernet to form an automatic mesh network."))

m.apply_on_parse = true
m.on_after_apply = function()
	sys.call("/etc/init.d/wiremesh restart >/dev/null 2>&1 &")
end

-- ========== General Settings ==========
local s = m:section(NamedSection, "general", "general", translate("General Settings"))
s.addremove = false
s.anonymous = true

s:tab("basic", translate("Basic Settings"))
s:tab("roaming", translate("Roaming Settings"))
s:tab("advanced", translate("Advanced Settings"))

-- Basic Tab
local enabled = s:taboption("basic", Flag, "enabled", translate("Enable"),
	translate("Enable wired mesh networking"))
enabled.default = "0"
enabled.rmempty = false

local routing_algo = s:taboption("basic", ListValue, "routing_algo", translate("Routing Algorithm"),
	translate("BATMAN_IV uses TQ (link quality) metric, BATMAN_V uses throughput metric"))
routing_algo:value("BATMAN_IV", "BATMAN_IV")
routing_algo:value("BATMAN_V", "BATMAN_V")
routing_algo.default = "BATMAN_IV"

local gw_mode = s:taboption("basic", ListValue, "gw_mode", translate("Gateway Mode"),
	translate("Set this node's role in the mesh: off (relay only), client (use mesh gateway for internet), server (provide internet to mesh)"))
gw_mode:value("off", translate("Off"))
gw_mode:value("client", translate("Client"))
gw_mode:value("server", translate("Server"))
gw_mode.default = "off"

local gw_bandwidth = s:taboption("basic", Value, "gw_bandwidth", translate("Gateway Bandwidth (Kbit/s)"),
	translate("Advertised gateway bandwidth, only used in server mode"))
gw_bandwidth.datatype = "uinteger"
gw_bandwidth.placeholder = "10000"
gw_bandwidth:depends("gw_mode", "server")

local orig_interval = s:taboption("basic", Value, "orig_interval", translate("OGM Interval (ms)"),
	translate("Originator message interval in milliseconds. Lower values improve convergence but increase overhead"))
orig_interval.datatype = "range(100,60000)"
orig_interval.default = "1000"
orig_interval.placeholder = "1000"

local bridge_lan = s:taboption("basic", Flag, "bridge_lan", translate("Bridge with LAN"),
	translate("Add the mesh interface (bat0) to the LAN bridge, allowing mesh clients to share the same subnet"))
bridge_lan.default = "1"

-- Roaming Tab
local roaming_enabled = s:taboption("roaming", Flag, "roaming_enabled",
	translate("Enable Roaming"),
	translate("Enable wireless client roaming optimization across mesh nodes. "
		.. "Uses 802.11r Fast BSS Transition and signal-based steering."))
roaming_enabled.default = "0"
roaming_enabled.rmempty = false
-- Store in roaming section
roaming_enabled.section = "roaming"

-- We need a separate section for roaming config
local r = m:section(NamedSection, "roaming", "roaming", translate("Roaming Threshold Configuration"))
r.addremove = false
r.anonymous = true

local rssi_low = r:option(Value, "rssi_threshold_low",
	translate("Signal Lower Threshold (dBm)"),
	translate("When a client's signal drops below this value, the AP will start steering "
		.. "the client to find a better node. Typical range: -80 to -70 dBm"))
rssi_low.datatype = "range(-95,-50)"
rssi_low.default = "-75"
rssi_low.placeholder = "-75"

local rssi_high = r:option(Value, "rssi_threshold_high",
	translate("Signal Upper Threshold (dBm)"),
	translate("A new AP will only accept the roaming client if signal is above this value. "
		.. "Must be higher than the lower threshold. This prevents switching to an AP "
		.. "that is only marginally better, avoiding ping-pong behavior."))
rssi_high.datatype = "range(-90,-40)"
rssi_high.default = "-65"
rssi_high.placeholder = "-65"

local hysteresis = r:option(Value, "roaming_hysteresis",
	translate("Hysteresis (dBm)"),
	translate("The new AP's signal must be at least this many dBm stronger than the current AP. "
		.. "Higher values prevent flip-flopping between APs in overlap zones. Recommended: 3-10 dBm"))
hysteresis.datatype = "range(0,30)"
hysteresis.default = "5"
hysteresis.placeholder = "5"

local roam_interval = r:option(Value, "roaming_interval",
	translate("Detection Interval (seconds)"),
	translate("How often to evaluate client signal strength for roaming decisions. "
		.. "Lower values react faster but increase CPU load"))
roam_interval.datatype = "range(1,60)"
roam_interval.default = "5"
roam_interval.placeholder = "5"

-- Roaming explanation
local roam_desc = r:option(DummyValue, "_roaming_desc", translate("How Roaming Works"))
roam_desc.rawhtml = true
roam_desc.cfgvalue = function()
	return translate(
		"<div style='padding:10px;background:#f0f6ff;border-radius:6px;margin-top:5px;line-height:1.8'>"
		.. "<strong>" .. translate("Roaming Mechanism") .. ":</strong><br/>"
		.. "1. " .. translate("When a client's signal drops below the <em>Lower Threshold</em>, the current AP begins steering the client away.") .. "<br/>"
		.. "2. " .. translate("A neighboring AP will only accept the client if the signal is above the <em>Upper Threshold</em>.") .. "<br/>"
		.. "3. " .. translate("Additionally, the new AP must be at least <em>Hysteresis</em> dBm stronger than the current AP.") .. "<br/>"
		.. "4. " .. translate("This dual-threshold + hysteresis design prevents rapid back-and-forth switching at coverage boundaries.") .. "<br/>"
		.. "</div>")
end

-- Advanced Tab
local bla = s:taboption("advanced", Flag, "bridge_loop_avoidance",
	translate("Bridge Loop Avoidance"),
	translate("Prevent layer 2 loops when the mesh is bridged with other networks"))
bla.default = "1"

local dat = s:taboption("advanced", Flag, "distributed_arp_table",
	translate("Distributed ARP Table"),
	translate("Speed up ARP resolution across the mesh by caching ARP entries on intermediate nodes"))
dat.default = "1"

local frag = s:taboption("advanced", Flag, "fragmentation",
	translate("Fragmentation"),
	translate("Allow batman-adv to fragment packets that exceed the interface MTU"))
frag.default = "1"

local agg = s:taboption("advanced", Flag, "aggregated_ogms",
	translate("Aggregated OGMs"),
	translate("Combine multiple originator messages into a single packet to reduce overhead"))
agg.default = "1"

local mcast = s:taboption("advanced", Flag, "multicast_mode",
	translate("Multicast Mode"),
	translate("Optimize multicast traffic distribution in the mesh"))
mcast.default = "1"

local hop = s:taboption("advanced", Value, "hop_penalty",
	translate("Hop Penalty"),
	translate("Penalty applied per hop to prefer shorter routes. Range 0-255, higher values prefer shorter paths"))
hop.datatype = "range(0,255)"
hop.default = "30"
hop.placeholder = "30"

local ap_iso = s:taboption("advanced", Flag, "ap_isolation",
	translate("AP Isolation"),
	translate("Prevent mesh clients from communicating directly with each other"))
ap_iso.default = "0"

local bond = s:taboption("advanced", Flag, "bonding",
	translate("Bonding"),
	translate("Combine multiple mesh links to the same neighbor for increased throughput"))
bond.default = "0"

-- ========== Mesh Interfaces ==========
local mi = m:section(TypedSection, "meshif", translate("Mesh Interfaces"),
	translate("Select which Ethernet ports participate in the mesh network. "
		.. "Each port connects to another mesh router via cable."))
mi.addremove = true
mi.anonymous = true
mi.template = "cbi/tblsection"

local ifname = mi:option(ListValue, "ifname", translate("Interface"))
-- Populate with available network devices
local devs = sys.net and sys.net.devices and sys.net.devices() or {}
if #devs == 0 then
	-- Fallback: read from /sys/class/net
	local dev_list = sys.exec("ls /sys/class/net/ 2>/dev/null") or ""
	for dev in dev_list:gmatch("%S+") do
		table.insert(devs, dev)
	end
end
for _, dev in ipairs(devs) do
	if dev:match("^eth") or dev:match("^lan") or dev:match("^wan") then
		ifname:value(dev, dev)
	end
end

local mtu = mi:option(Value, "mtu", translate("MTU"),
	translate("Recommended 1536 for wired mesh (adds ~32 bytes batman-adv overhead)"))
mtu.datatype = "range(1280,9000)"
mtu.default = "1536"
mtu.placeholder = "1536"

return m
