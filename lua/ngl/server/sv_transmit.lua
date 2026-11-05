-- Not sending far NPCs to clients.
--
-- Every NPC in a player's PVS is normally sent to that player's client, even
-- when the client won't draw it (past ngl_cl_draw_range or the fog). The
-- client still takes its updates, moves it between them and keeps it in its
-- entity lists. Here each NPC further from a player than that player's own
-- draw range (plus a margin) stops being sent to that player
-- (Entity:SetPreventTransmit). Closer again, it is sent again.
--
-- Only what the player receives changes: the NPC still runs, fights and can
-- shoot that player.
--
-- Cost: each NPC is checked against each player about four times a second,
-- spread over the ticks. NPCs coming back in range are let through a few per
-- tick, so turning onto a big fight doesn't send hundreds of full entity
-- updates in one tick.

local Core = NGL.Core
local IsValid = IsValid

local cvCull = CreateConVar("ngl_net_cull", "1", FCVAR_ARCHIVE,
	"1 = NGL NPCs further from a player than that player's ngl_cl_draw_range (times ngl_net_cull_margin) are not sent to that player at all. 0 = send everything in the PVS as usual.", 0, 1)
local cvMargin = CreateConVar("ngl_net_cull_margin", "1.15", FCVAR_ARCHIVE,
	"NPCs stop being sent this many times further out than the player's draw range, and are sent again inside it, so they're already there when they come into view.", 1, 4)
local cvMaxRange = CreateConVar("ngl_net_cull_max", "0", FCVAR_ARCHIVE,
	"Server cap on the range NPCs are sent to players, whatever their own draw range (0 = no cap; a player with ngl_cl_draw_range 0 then gets every NPC).", 0, 100000)

local CHECK_PERIOD = 0.25   -- seconds to go round every NPC once
local SHOW_PER_TICK = 24    -- NPCs let back in per player per tick
local DEFAULT_RANGE = 6000  -- ngl_cl_draw_range's default

local cursor = 0
-- Per player: range squared (hide past it), show range squared, view
-- position, NPCs let back in this tick.
local view = {}

local function viewPos(ply)
	local ve = ply:GetViewEntity()
	if IsValid(ve) and ve ~= ply then return ve:GetPos() end
	return ply:EyePos()
end

local function rangeFor(ply)
	local r = ply:GetInfoNum("ngl_cl_draw_range", DEFAULT_RANGE)
	local cap = cvMaxRange:GetFloat()
	if r <= 0 then r = cap > 0 and cap or math.huge
	elseif cap > 0 then r = math.min(r, cap) end
	return r
end

-- Sent again to everyone: when culling is turned off, or for one NPC.
local function showAll(npc)
	local hidden = npc.NGLNetHidden
	if not hidden then return end
	for ply in pairs(hidden) do
		if IsValid(ply) then npc:SetPreventTransmit(ply, false) end
	end
	npc.NGLNetHidden = nil
end

local wasOn = false

hook.Add("Tick", "NGL.NetCull", function()
	local list = Core.List
	local n = #list
	local on = cvCull:GetBool()
	if not on then
		if wasOn then
			for i = 1, n do
				local npc = list[i]
				if IsValid(npc) then showAll(npc) end
			end
			wasOn = false
		end
		return
	end
	wasOn = true
	if n == 0 then return end

	local plys = player.GetHumans()
	local np = #plys
	if np == 0 then return end
	local margin = cvMargin:GetFloat()
	for p = 1, np do
		local ply = plys[p]
		local v = view[p] or {}
		view[p] = v
		local r = rangeFor(ply)
		v.ply = ply
		v.pos = viewPos(ply)
		v.show = r * r
		v.hide = (r * margin) ^ 2
		v.left = SHOW_PER_TICK
	end

	local per = math.min(n, math.ceil(n * engine.TickInterval() / CHECK_PERIOD))
	for _ = 1, per do
		cursor = cursor % n + 1
		local npc = list[cursor]
		-- A dying NPC stays as it is: far away its client ragdoll isn't wanted.
		if IsValid(npc) and not npc.NGLDying then
			local pos = npc:GetPos()
			-- Vehicles are drawn twice as far (cl_init.lua).
			local k = npc.IsVehicleNPC and 4 or 1
			local hidden = npc.NGLNetHidden
			for p = 1, np do
				local v = view[p]
				local ply = v.ply
				local d = pos:DistToSqr(v.pos)
				local isHidden = hidden and hidden[ply]
				if isHidden then
					if d < v.show * k and v.left > 0 then
						v.left = v.left - 1
						hidden[ply] = nil
						npc:SetPreventTransmit(ply, false)
					end
				elseif d > v.hide * k then
					if not hidden then
						hidden = setmetatable({}, { __mode = "k" })
						npc.NGLNetHidden = hidden
					end
					hidden[ply] = true
					npc:SetPreventTransmit(ply, true)
				end
			end
		end
	end
end)

-- How many NPCs each player is not sent right now.
concommand.Add("ngl_net_status", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	local counts = {}
	for _, npc in ipairs(Core.List) do
		if IsValid(npc) and npc.NGLNetHidden then
			for p in pairs(npc.NGLNetHidden) do
				if IsValid(p) then counts[p] = (counts[p] or 0) + 1 end
			end
		end
	end
	local lines = { string.format("[NGL] %d NPCs, culling %s", #Core.List, cvCull:GetBool() and "on" or "off") }
	for _, p in ipairs(player.GetHumans()) do
		lines[#lines + 1] = string.format("  %s: %d not sent (range %.0f)", p:Nick(), counts[p] or 0, rangeFor(p))
	end
	for _, l in ipairs(lines) do
		print(l)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, l) end
	end
end)
