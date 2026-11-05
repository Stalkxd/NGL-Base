-- Server side of two tools (lua/weapons/gmod_tool/stools):
--   NGL NPC Tracker (ngl_track): pick NPCs and watch where they're going:
--     their path, jumps, goal and what they're doing, drawn on your screen.
--   NGL NPC Mover (ngl_move): pick NPCs and send them somewhere (a move
--     order, the same one squad leaders give).
-- Superadmins only. Tracking costs nothing for NPCs nobody tracks: the
-- tracked ones are sent five times a second to the players tracking them.

NGL.Tools = NGL.Tools or {}
local T = NGL.Tools

local MAX_TRACKED = 8
local MAX_SELECTED = 32
local SEND_EVERY = 0.2
local MAX_POINTS = 40

util.AddNetworkString("ngl_track")
util.AddNetworkString("ngl_move_sel")

local function allowed(ply) return IsValid(ply) and ply:IsSuperAdmin() end
local function say(ply, msg) if IsValid(ply) then ply:PrintMessage(HUD_PRINTCENTER, msg) end end
local function isNPC(e) return IsValid(e) and e.IsNGLNPC and not e.NGLDying end

-- The NPC the trace hit, or the NGL NPC nearest the hit spot (within 48).
local function pickNPC(trace)
	local e = trace.Entity
	if isNPC(e) then return e end
	local best, bestD = nil, 48 * 48
	for _, n in ipairs(ents.FindInSphere(trace.HitPos, 48)) do
		if isNPC(n) then
			local d = n:GetPos():DistToSqr(trace.HitPos)
			if d < bestD then best, bestD = n, d end
		end
	end
	return best
end
T.PickNPC = pickNPC

local function liveList(t)
	local out = {}
	for e in pairs(t) do
		if isNPC(e) then out[#out + 1] = e else t[e] = nil end
	end
	return out
end

----------------------------------------------------------------------------
-- Tracker
----------------------------------------------------------------------------

-- button: "left" (track the NPC aimed at, or stop), "right" (stop all).
function T.Track(ply, trace, button)
	if not allowed(ply) then say(ply, "NGL NPC Tracker: superadmins only") return false end
	ply.NGLTracked = ply.NGLTracked or {}
	local set = ply.NGLTracked
	if button == "right" then
		ply.NGLTracked = {}
		T.SendTrack(ply)
		say(ply, "Tracking nothing")
		return true
	end
	local npc = pickNPC(trace)
	if not npc then return false end
	if set[npc] then
		set[npc] = nil
		say(ply, "Stopped tracking " .. npc:GetClass())
	else
		if #liveList(set) >= MAX_TRACKED then say(ply, "Tracking " .. MAX_TRACKED .. " already (right click: stop all)") return false end
		set[npc] = true
		say(ply, "Tracking " .. npc:GetClass())
	end
	T.SendTrack(ply)
	return true
end

-- What it's doing, in a few words.
local function stateText(npc)
	local parts = { npc:GetClass():gsub("^ngl_", ""), npc:GetAIMode() }
	local tr = npc.NGLTraverse
	if tr then
		parts[#parts + 1] = tr.move == "up" and "jumping up" or tr.move == "climb" and "climbing" or "jumping"
	end
	local o = npc.NGLOrder
	if o then parts[#parts + 1] = "order: " .. tostring(o.kind) end
	local sq = npc.NGLSquad
	if sq then parts[#parts + 1] = sq.leader == npc and "squad leader" or "in squad" end
	local en = npc.NGLEnemy
	if IsValid(en) then
		parts[#parts + 1] = "enemy: " .. (en:IsPlayer() and en:Nick() or en:GetClass())
	end
	if npc.NGLPathPending then parts[#parts + 1] = "finding a path"
	elseif npc.NGLPath then parts[#parts + 1] = "on a path"
	elseif npc.NGLGoal then parts[#parts + 1] = npc.NGLDirect and "going straight" or "moving"
	else parts[#parts + 1] = "standing" end
	return table.concat(parts, " | ")
end
T.StateText = stateText

local MOVE_CODE = { jump = 1, up = 2, climb = 3 }

function T.SendTrack(ply)
	local list = liveList(ply.NGLTracked or {})
	net.Start("ngl_track")
	net.WriteUInt(#list, 4)
	for _, npc in ipairs(list) do
		net.WriteUInt(npc:EntIndex(), 16)
		net.WriteVector(npc:GetPos())
		net.WriteString(stateText(npc))
		-- Where it's heading: the rest of its path (with jumps marked), then
		-- the final goal.
		local pts, moves = {}, {}
		local path = npc.NGLPath
		if path then
			local links = path.links
			for k = math.max(npc.NGLPathIdx or 1, 1), #path do
				if #pts >= MAX_POINTS then break end
				pts[#pts + 1] = path[k]
				local L = links and links[k]
				moves[#pts] = L and L.move and MOVE_CODE[L.move] or 0
			end
		end
		local goal = npc.NGLGoal
		if goal and #pts < MAX_POINTS then
			local last = pts[#pts]
			if not last or last:DistToSqr(goal) > 16 * 16 then
				pts[#pts + 1] = goal
				moves[#pts] = 0
			end
		end
		-- The jump under way, if any: its landing spot first.
		local tr = npc.NGLTraverse
		net.WriteBool(tr ~= nil)
		if tr then net.WriteVector(tr.to) end
		net.WriteUInt(#pts, 6)
		for k, p in ipairs(pts) do
			net.WriteVector(p)
			net.WriteUInt(moves[k] or 0, 2)
		end
		local o = npc.NGLOrder
		net.WriteBool(o ~= nil and o.pos ~= nil)
		if o and o.pos then net.WriteVector(o.pos) end
	end
	net.Send(ply)
end

timer.Create("NGL.Tools.Track", SEND_EVERY, 0, function()
	for _, ply in ipairs(player.GetAll()) do
		local set = ply.NGLTracked
		if set and next(set) and allowed(ply) then T.SendTrack(ply) end
	end
end)

----------------------------------------------------------------------------
-- Mover
----------------------------------------------------------------------------

local function sendSelection(ply)
	local list = liveList(ply.NGLSelected or {})
	net.Start("ngl_move_sel")
	net.WriteUInt(#list, 6)
	for _, e in ipairs(list) do net.WriteUInt(e:EntIndex(), 16) end
	net.Send(ply)
end
T.SendSelection = sendSelection

-- Spots for n NPCs round `pos`, about `gap` apart, on the nav grid when
-- there is one (rings: 1 in the middle, then 6, 12...).
function T.SpreadSpots(pos, n, gap)
	local spots = {}
	local ring, k = 0, 0
	while #spots < n do
		local count = ring == 0 and 1 or ring * 6
		for i = 1, count do
			if #spots >= n then break end
			local a = (i - 1) / count * math.pi * 2 + ring * 0.5
			local p = Vector(pos.x + math.cos(a) * gap * ring, pos.y + math.sin(a) * gap * ring, pos.z)
			local g = NGL.Core and NGL.Core.GridSpot and NGL.Core.GridSpot(p)
			-- Snapped to the grid only when that stays close (not another floor).
			if g and g:DistToSqr(p) < (gap * 1.5) ^ 2 then p = g end
			spots[#spots + 1] = p
		end
		ring = ring + 1
		k = k + 1
		if k > 20 then break end
	end
	return spots
end

-- left: pick or drop the NPC aimed at (or, aiming at the ground with NPCs
-- picked, send them there). right: send the picked NPCs there. reload:
-- drop them all. opts: { run = bool, hold = bool }.
function T.Move(ply, trace, button, opts)
	if not allowed(ply) then say(ply, "NGL NPC Mover: superadmins only") return false end
	ply.NGLSelected = ply.NGLSelected or {}
	local sel = ply.NGLSelected
	if button == "reload" then
		ply.NGLSelected = {}
		sendSelection(ply)
		return true
	end
	local npc = button == "left" and pickNPC(trace)
	if npc then
		if sel[npc] then
			sel[npc] = nil
		elseif #liveList(sel) >= MAX_SELECTED then
			say(ply, "Picked " .. MAX_SELECTED .. " already")
			return false
		else
			sel[npc] = true
		end
		sendSelection(ply)
		return true
	end
	local list = liveList(sel)
	if #list == 0 then say(ply, "Left click NPCs to pick them first") return false end
	local spots = T.SpreadSpots(trace.HitPos, #list, 56)
	-- Nearest NPC to the middle spot, and so on, so they don't cross over.
	table.sort(list, function(a, b) return a:GetPos():DistToSqr(trace.HitPos) < b:GetPos():DistToSqr(trace.HitPos) end)
	local n = 0
	for k, e in ipairs(list) do
		local ok = e:GiveOrder({ kind = "move", pos = spots[k], run = opts.run, hold = opts.hold,
			holdTime = opts.hold and 60 or nil, radius = 40, time = 120, byPlayer = true })
		if ok then n = n + 1 end
	end
	say(ply, string.format("Sent %d NPC%s there", n, n == 1 and "" or "s"))
	return true
end

-- ngl_debug_target: what's going on with the NGL NPC closest to where you
-- aim (within 150 units of the line), even one bullets don't hit: health,
-- solidity, collision box and group, hitboxes, lag compensation, whether it
-- is still in the AI list, and what a bullet from your eyes to its middle
-- hits instead of it. For "it can't be killed" reports.
concommand.Add("ngl_debug_target", function(ply)
	if not IsValid(ply) or not ply:IsSuperAdmin() then return end
	local function say(msg)
		print(msg)
		ply:PrintMessage(HUD_PRINTCONSOLE, msg)
	end
	local eye, dir = ply:EyePos(), ply:GetAimVector()
	local best, bestD
	for _, e in ipairs(ents.GetAll()) do
		if e.IsNGLNPC and IsValid(e) then
			local c = e:WorldSpaceCenter()
			local along = (c - eye):Dot(dir)
			if along > 0 then
				local off = (eye + dir * along):Distance(c)
				if off < 150 and (not bestD or off < bestD) then best, bestD = e, off end
			end
		end
	end
	if not best then say("[NGL] No NGL NPC near where you aim.") return end
	local e = best
	local mins, maxs = e:GetCollisionBounds()
	local Core = NGL.Core
	say(string.format("[NGL] %s #%d at %s, %.0f units away", e:GetClass(), e:EntIndex(), tostring(e:GetPos()), eye:Distance(e:GetPos())))
	say(string.format("  health %d / %d, dying %s, in AI list %s, faction %s",
		e:Health(), e:GetMaxHealth(), tostring(e.NGLDying or false), tostring(Core and Core.Index and Core.Index[e] ~= nil), tostring(e.Faction)))
	say(string.format("  solid %d, solid flags %d, collision group %d, box %s .. %s, hitboxes %d",
		e:GetSolid(), e:GetSolidFlags(), e:GetCollisionGroup(), tostring(mins), tostring(maxs), e:GetHitBoxCount(0) or -1))
	say(string.format("  lag compensated %s, leaping %s, traversing %s, on ground %s",
		tostring(e.IsLagCompensated and e:IsLagCompensated()), tostring(e.NGLLeapState ~= nil), tostring(e.NGLTraverse ~= nil),
		tostring(e.loco and e.loco:IsOnGround())))
	local tr = util.TraceLine({ start = eye, endpos = e:WorldSpaceCenter(), mask = MASK_SHOT, filter = ply })
	local hit = tr.Entity
	say(string.format("  a shot at its middle hits: %s%s (hitgroup %d)",
		IsValid(hit) and hit:GetClass() or (tr.HitWorld and "the world" or "nothing"),
		hit == e and " (it)" or "", tr.HitGroup or 0))
	local inSolid = util.TraceHull({ start = e:GetPos(), endpos = e:GetPos(), mins = mins, maxs = maxs, mask = MASK_NPCSOLID_BRUSHONLY, filter = e })
	say("  stuck in the world: " .. tostring(inSolid.StartSolid))
end)
