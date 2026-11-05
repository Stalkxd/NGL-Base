-- NGL settings in the spawn menu: Q menu, Utilities, NGL Base.
--
-- Two pages. "Server settings": the server's most useful settings as
-- sliders and checkboxes, and buttons for its main commands. Anyone can
-- look; only superadmins (or the host in singleplayer) can change them:
-- a change is sent to the server, which checks who asked and that it's one
-- of the settings listed here, then sets it. "Client settings": this
-- client's drawing settings, changed straight away.
--
-- Each row: { convar, label, min, max, decimals } is a slider, decimals
-- false a checkbox; { cmd = "...", label = "..." } a button. help: a line
-- under it.

NGL.Settings = NGL.Settings or {}
local S = NGL.Settings

S.Server = {
	{ title = "AI" },
	{ "ngl_ai_budget", "AI budget (ms a tick)", 0.5, 20, 1, help = "CPU time the AI may use each tick. Higher: smarter crowds, slower server." },
	{ "ngl_ai_near", "Full AI range", 300, 6000, 0, help = "NPCs this close to a player think at the full rate." },
	{ "ngl_ai_mid", "Reduced AI range", 1000, 15000, 0 },
	{ "ngl_ai_melee_slots", "Melee attackers per target", 0, 12, 0, help = "How many melee NPCs attack one target at once; the rest wait round it. 0 = no limit." },
	{ "ngl_anim_detail_range", "Full animation range", 0, 6000, 0 },
	{ title = "Network" },
	{ "ngl_net_cull", "Don't send NPCs players can't see", false },
	{ "ngl_lagcomp_range", "Lag compensation range", 0, 10000, 0 },
	{ title = "Doors" },
	{ "ngl_door_breach", "Kicked doors: 0 open, 1 burst, 2 off the hinges", 0, 2, 0 },
	{ "ngl_door_respawn", "Broken doors come back after (s)", 0, 600, 0 },
	{ title = "Zombies and bodies" },
	{ "ngl_zombie_headcrabs", "Headcrabs come off dead zombies", false },
	{ "ngl_headcrab_max", "Most headcrabs at once", 0, 200, 0 },
	{ "ngl_ragdolls", "Ragdolls when NPCs die", false },
	{ "ngl_apc_wreck_time", "APC wrecks stay (s)", 0, 600, 0 },
	{ title = "Reinforcements" },
	{ "ngl_reinforce_apc", "APCs come in by dropship", false },
	{ "ngl_reinforce_onfoot", "Soldiers come in on foot", false },
	{ "ngl_reinforce_limit", "Most reinforcement waves", 0, 20, 0 },
	{ "ngl_reinforce_cooldown", "Between waves (s)", 10, 600, 0 },
	{ "ngl_dropship_max", "Most dropships at once", 0, 8, 0 },
	{ "ngl_dropship_vulnerable", "Dropships can be shot down", false },
	{ title = "Effects" },
	{ "ngl_fx_impacts", "Bullet impacts a second", 0, 300, 0 },
	{ "ngl_fx_sounds", "Gun sounds a second", 0, 200, 0 },
	{ title = "Nav grid" },
	{ "ngl_nav_auto", "Make the grid on its own on new maps", false },
	{ "ngl_nav_source", "No grid: use the map's navmesh", false },
	{ "ngl_nav_budget", "Path search budget (ms a tick)", 0.1, 20, 1 },
	{ cmd = "ngl_nav_generate", label = "Make the nav grid now", help = "Rebuilds this map's grid (a minute or two)." },
	{ cmd = "ngl_nav_info", label = "Nav grid info (console)" },
	{ title = "Commands" },
	{ cmd = "ngl_status", label = "Status (console)" },
	{ cmd = "ngl_spawn_clear", label = "Remove all NGL NPCs" },
	{ cmd = "ngl_bench_stop", label = "Stop the benchmark" },
}

S.Client = {
	{ title = "Far NPCs" },
	{ "ngl_cl_draw_range", "Draw NPCs up to", 1000, 30000, 0 },
	{ "ngl_cl_impostor", "Far NPCs as pictures", false },
	{ "ngl_cl_impostor_range", "Pictures from", 500, 20000, 0 },
	{ "ngl_cl_impostor_quality", "Picture sharpness (next map)", 1, 2, 0 },
	{ "ngl_cl_occlusion", "Skip NPCs behind walls", false },
	{ title = "Detail" },
	{ "ngl_cl_lod_range", "Full model detail up to", 0, 10000, 0 },
	{ "ngl_cl_shadow_range", "Shadows up to", 0, 10000, 0 },
	{ "ngl_cl_weapon_range", "Weapons drawn up to", 0, 10000, 0 },
	{ "ngl_cl_flex_range", "Faces up to", 0, 5000, 0 },
	{ "ngl_cl_decal_range", "Blood and bullet marks up to", 0, 5000, 0 },
	{ title = "Ragdolls" },
	{ "ngl_cl_ragdoll_max", "Most ragdolls", 0, 128, 0 },
	{ "ngl_cl_ragdoll_time", "Ragdolls stay (s)", 0, 300, 0 },
	{ "ngl_cl_ragdoll_range", "Ragdolls up to", 0, 10000, 0 },
	{ cmd = "ngl_cl_ragdoll_clear", label = "Clear ragdolls" },
	{ cmd = "ngl_cl_impostor_reset", label = "Remake far NPC pictures" },
}

local allowed = {}
for _, row in ipairs(S.Server) do
	if row[1] then allowed[row[1]] = row end
end

if SERVER then
	util.AddNetworkString("ngl_settings")

	local function sendValues(ply)
		net.Start("ngl_settings")
		local n = 0
		for _ in pairs(allowed) do n = n + 1 end
		net.WriteUInt(n, 8)
		for name in pairs(allowed) do
			local cv = GetConVar(name)
			net.WriteString(name)
			net.WriteString(cv and cv:GetString() or "")
		end
		net.WriteBool(game.SinglePlayer() or ply:IsSuperAdmin())
		net.Send(ply)
	end

	net.Receive("ngl_settings", function(_, ply)
		if not IsValid(ply) then return end
		if net.ReadBool() then -- a change
			local name, value = net.ReadString(), net.ReadString()
			if not (game.SinglePlayer() or ply:IsSuperAdmin()) then return end
			local row = allowed[name]
			local cv = GetConVar(name)
			if not row or not cv then return end
			local v = tonumber(value)
			if not v then return end
			if row[3] == false then v = v ~= 0 and 1 or 0
			else v = math.Clamp(v, row[3], row[4]) end
			cv:SetString(tostring(v))
			print(string.format("[NGL] %s set %s to %s", ply:Nick(), name, tostring(v)))
		end
		sendValues(ply)
	end)
	return
end

-- Client: the two pages.
local serverRows = {} -- convar -> control on the server page
local serverHint

local function ask(name, value)
	net.Start("ngl_settings")
	net.WriteBool(name ~= nil)
	if name then
		net.WriteString(name)
		net.WriteString(tostring(value))
	end
	net.SendToServer()
end

net.Receive("ngl_settings", function()
	local n = net.ReadUInt(8)
	local vals = {}
	for _ = 1, n do
		local k = net.ReadString()
		vals[k] = net.ReadString()
	end
	local canEdit = net.ReadBool()
	for name, ctl in pairs(serverRows) do
		if IsValid(ctl) and vals[name] then
			ctl.NGLSetting = true
			if ctl.SetChecked then ctl:SetChecked(tonumber(vals[name]) ~= 0)
			else ctl:SetValue(tonumber(vals[name]) or 0) end
			ctl.NGLSetting = nil
			ctl:SetEnabled(canEdit)
		end
	end
	if IsValid(serverHint) then
		serverHint:SetText(canEdit and "Changes are made on the server right away."
			or "Only superadmins can change these.")
	end
end)

local function build(panel, rows, server)
	panel:ClearControls()
	if server then
		serverRows = {}
		serverHint = panel:Help("Asking the server...")
	end
	for _, row in ipairs(rows) do
		if row.title then
			local l = panel:Help(row.title)
			l:SetFont("DermaDefaultBold")
		elseif row.cmd then
			local cmd = row.cmd
			local b = panel:Button(row.label)
			b.DoClick = function() RunConsoleCommand(cmd) end
		elseif row[3] == false then
			if server then
				local name = row[1]
				local c = panel:CheckBox(row[2])
				c.OnChange = function(self, v)
					if self.NGLSetting then return end
					ask(name, v and 1 or 0)
				end
				serverRows[name] = c
			else
				panel:CheckBox(row[2], row[1])
			end
		else
			if server then
				local name = row[1]
				local s = panel:NumSlider(row[2], nil, row[3], row[4], row[5])
				-- Sent when the slider stops moving, not every step of a drag.
				s.OnValueChanged = function(self, v)
					if self.NGLSetting then return end
					timer.Create("NGL.Settings." .. name, 0.3, 1, function() ask(name, v) end)
				end
				serverRows[name] = s
			else
				panel:NumSlider(row[2], row[1], row[3], row[4], row[5])
			end
		end
		if row.help then panel:ControlHelp(row.help) end
	end
	if server then ask(nil) end
end

hook.Add("AddToolMenuCategories", "NGL.Settings", function()
	spawnmenu.AddToolCategory("Utilities", "NGL Base", "NGL Base")
end)
hook.Add("PopulateToolMenu", "NGL.Settings", function()
	spawnmenu.AddToolMenuOption("Utilities", "NGL Base", "ngl_settings_server", "Server settings", "", "", function(panel)
		build(panel, S.Server, true)
	end)
	spawnmenu.AddToolMenuOption("Utilities", "NGL Base", "ngl_settings_client", "Client settings", "", "", function(panel)
		build(panel, S.Client, false)
	end)
end)
-- Fresh values from the server each time the spawn menu opens.
hook.Add("OnSpawnMenuOpen", "NGL.Settings", function()
	if next(serverRows) then ask(nil) end
end)
