-- NGL core: factions, spatial grid, central AI scheduler and combat.
--
-- Cost model (why it is built this way):
--   * Per tick, each NPC only runs BehaveUpdate (steer + face, a few engine calls).
--   * Decisions run here, in ONE hook, at a rate that depends on how close the
--     nearest player is, under a hard CPU budget per tick.
--   * Enemy search uses a spatial grid, so it scales with the NPCs nearby, not
--     with every NPC on the map (the old brute force made cost grow with N^2).
--   * Far from players, shooting is a single trace with accumulated damage, so
--     battles resolve at the same pace without bullets, tracers or sounds.

NGL.Core = NGL.Core or {}
local Core = NGL.Core

local SysTime, CurTime = SysTime, CurTime
local IsValid = IsValid
local floor, min, max, abs, random, Rand = math.floor, math.min, math.max, math.abs, math.random, math.Rand

local cvBudget = CreateConVar("ngl_ai_budget", "3", FCVAR_ARCHIVE,
	"Max milliseconds of NGL AI decisions per server tick. Leftover NPCs think next tick.", 0.1, 50)
local cvNear = CreateConVar("ngl_ai_near", "1500", FCVAR_ARCHIVE, "Within this distance of a player, NPCs think at the fast rate.", 0, 50000)
local cvMid = CreateConVar("ngl_ai_mid", "4000", FCVAR_ARCHIVE, "Within this distance of a player, NPCs think at the medium rate.", 0, 50000)
local cvRateNear = CreateConVar("ngl_ai_rate_near", "0.1", FCVAR_ARCHIVE, "Seconds between AI thinks near players.", 0, 5)
local cvRateMid = CreateConVar("ngl_ai_rate_mid", "0.3", FCVAR_ARCHIVE, "Seconds between AI thinks at medium distance.", 0, 5)
local cvRateFar = CreateConVar("ngl_ai_rate_far", "1.0", FCVAR_ARCHIVE, "Seconds between AI thinks far from every player.", 0, 10)
local cvVisual = CreateConVar("ngl_ai_visual_range", "3000", FCVAR_ARCHIVE, "NPCs this close to a player fire real bullets with tracers and sound; further away they use one silent trace.", 0, 50000)
local cvDetail = CreateConVar("ngl_anim_detail_range", "1500", FCVAR_ARCHIVE, "NPCs this close to a player get full animation detail (aim and strafe poses, firing/reload/flinch gestures, aimed walk and run). Further away they play plain idle/walk/run cycles, which is much cheaper for the server and every client.", 0, 50000)
local DETAIL_LEAVE = 1.15 * 1.15 -- leave full detail a bit further out than we enter it, so it doesn't flicker at the edge
local cvPVS = CreateConVar("ngl_ai_pvs", "1", FCVAR_ARCHIVE, "1 = NPCs no player can see (outside every player's PVS, e.g. behind walls) are treated like far ones even when close: no animation detail, silent shots, the medium think rate. 0 = by distance only.", 0, 1)
local cvRail = CreateConVar("ngl_ai_rail_range", "4000", FCVAR_ARCHIVE, "NPCs further than this from every player, that no player can see, follow their path by moving straight along it at each think instead of walking with the NextBot locomotion every tick. 0 = never.", 0, 50000)
local cvRateSleep = CreateConVar("ngl_ai_rate_sleep", "3", FCVAR_ARCHIVE, "Seconds between AI thinks for idle NPCs (no enemy, no order, standing still) far from every player. Damage, an ally's alert or an order wakes them at once.", 0, 30)
local cvLagRange = CreateConVar("ngl_lagcomp_range", "3000", FCVAR_ARCHIVE, "NPCs further than this from every player are not lag compensated (when the engine compensates them at all). 0 = leave lag compensation alone.", 0, 50000)
local cvShare = CreateConVar("ngl_ai_share_sight", "1", FCVAR_ARCHIVE, "1 = squad and group members near their leader pick enemies from the leader's search instead of searching the grid themselves.", 0, 1)

----------------------------------------------------------------------------
-- Factions
----------------------------------------------------------------------------

Core.Relations = Core.Relations or {}
local Relations = Core.Relations

-- NGL.SetRelation("rebels", "player", D_LI)  -- symmetric by default
function NGL.SetRelation(a, b, disp, oneWay)
	Relations[a] = Relations[a] or {}
	Relations[a][b] = disp
	if not oneWay then
		Relations[b] = Relations[b] or {}
		Relations[b][a] = disp
	end
end

function NGL.GetRelation(a, b)
	if a == b then return D_LI end
	local r = Relations[a]
	return (r and r[b]) or D_HT
end

local ignorePlayers = GetConVar("ai_ignoreplayers")
local aiDisabled = GetConVar("ai_disabled")

function Core.IsHostile(npc, ent)
	if ent:IsPlayer() then
		if npc.NGLIgnorePlayers or not ent:Alive() then return false end
		if ignorePlayers and ignorePlayers:GetBool() then return false end
		return NGL.GetRelation(npc.Faction, "player") == D_HT
	end
	if ent.IsNGLNPC then
		return not ent.NGLDying and NGL.GetRelation(npc.Faction, ent.Faction) == D_HT
	end
	return false
end

-- Teammates don't hurt each other.
hook.Add("EntityTakeDamage", "NGL.Core.Damage", function(ent, dmginfo)
	if not ent.IsNGLNPC then return end
	local attacker = dmginfo:GetAttacker()
	if IsValid(attacker) and attacker.IsNGLNPC and attacker ~= ent
		and NGL.GetRelation(attacker.Faction, ent.Faction) == D_LI then
		return true
	end
	if ent:OnDamaged(dmginfo) == true then return true end
	Core.Wake(ent) -- a sleeping NPC (ngl_ai_rate_sleep) reacts at once
end)

-- Thinks on the next tick (sleeping or far NPCs that something happened to).
function Core.Wake(npc)
	local now = CurTime()
	if npc.NGLNextThink and npc.NGLNextThink > now then npc.NGLNextThink = now end
end

----------------------------------------------------------------------------
-- Spatial grid
----------------------------------------------------------------------------

local CELL = 1024
local OFFSET = 512 -- keeps cell coords positive for any map up to +-500k units
local cells = {}
Core.Cells = cells

local function cellKey(x, y)
	return (floor(x / CELL) + OFFSET) * 4096 + (floor(y / CELL) + OFFSET)
end

local function gridUpdate(ent, pos)
	local k = cellKey(pos.x, pos.y)
	local old = ent.NGLCell
	if old == k then return end
	if old then
		local c = cells[old]
		if c then c[ent] = nil end
	end
	local c = cells[k]
	if not c then
		c = {}
		cells[k] = c
	end
	c[ent] = true
	ent.NGLCell = k
end

local function gridRemove(ent)
	local old = ent.NGLCell
	if old then
		local c = cells[old]
		if c then c[ent] = nil end
		ent.NGLCell = nil
	end
end

----------------------------------------------------------------------------
-- NPC list (array for fast round-robin, index map for O(1) removal)
----------------------------------------------------------------------------

Core.List = Core.List or {}
Core.Index = Core.Index or {}
local List, Index = Core.List, Core.Index
local cursor = 0

function Core.Add(npc)
	if Index[npc] then return end
	List[#List + 1] = npc
	Index[npc] = #List
	npc.NGLNextThink = CurTime() + Rand(0, 0.2)
	npc.NGLLastThink = CurTime()
	npc.NGLNextRetarget = 0
	npc.NGLNextStrafe = 0
	npc.NGLFireAccum = 0
	-- Lag compensated by the engine? Then only near players (scheduler).
	npc.NGLLagDefault = npc.IsLagCompensated and npc:IsLagCompensated() or false
	npc.NGLLagOn = npc.NGLLagDefault
	gridUpdate(npc, npc:GetPos())
end

function Core.Remove(npc)
	local i = Index[npc]
	if not i then return end
	local n = #List
	local last = List[n]
	List[i] = last
	Index[last] = i
	List[n] = nil
	Index[npc] = nil
	gridRemove(npc)
	if npc.NGLSquad then npc.NGLSquad:Remove(npc) end
	if npc.NGLSlotTarget then Core.ReleaseSlot(npc) end
end

function Core.Count() return #List end

----------------------------------------------------------------------------
-- Perception
----------------------------------------------------------------------------

local players = {}
local plyPos = {} -- their positions, once per tick (scheduler)

-- Line of sight: walls, and doors and props too (a brush-only trace saw
-- straight through prop doors, crates and cars, so NPCs shot at you through
-- them). A trace has to take CONTENTS_MONSTER to hit any model entity, so
-- it would stop on every NPC in a crowd as well; with the NGL NPCs'
-- collision group it passes through them (they don't collide with each
-- other) in the engine, without a Lua filter. Glass and grates don't block
-- (no CONTENTS_WINDOW / GRATE): you can be seen and shot through a window.
local LOS_MASK = bit.bor(CONTENTS_SOLID, CONTENTS_MOVEABLE, CONTENTS_MONSTER, CONTENTS_BLOCKLOS)
local losTrace = { mask = LOS_MASK, collisiongroup = COLLISION_GROUP_NPC_SCRIPTED }
local losResult = {}
losTrace.output = losResult

local function lineOfSight(from, ent, ignore)
	losTrace.start = from
	losTrace.endpos = ent:WorldSpaceCenter()
	losTrace.filter = ignore
	util.TraceLine(losTrace)
	if not losResult.Hit then return true end
	local hit = losResult.Entity
	return hit == ent or (IsValid(hit) and hit:GetParent() == ent)
end
Core.LineOfSight = lineOfSight

-- Shared sight checks (ngl_ai_share_los): a squad standing together, or
-- a horde running at one player, all ask "can I see it?" from nearly the
-- same spot within the same moment. The answer only depends on the walls
-- between (NGL NPCs don't block each other's sight), so each target keeps
-- its last few answers, and an NPC whose eyes are within LOS_SHARE_DIST of
-- where one was asked from, less than LOS_SHARE_TIME ago, takes it instead
-- of tracing again.
local cvShareLos = CreateConVar("ngl_ai_share_los", "1", FCVAR_ARCHIVE,
	"1 = NGL NPCs standing close together share line-of-sight checks to the same target (one trace answers for all of them for a moment).", 0, 1)
local LOS_SHARE_TIME = 0.3
local LOS_SHARE_SQR = 48 * 48
local LOS_SLOTS = 4
local losCount -- NGL.FX.Count (sv_fx.lua, loaded later): losTraces, losShared

local function canSee(npc, from, ent)
	if not cvShareLos:GetBool() then return lineOfSight(from, ent, npc) end
	losCount = losCount or (NGL.FX and NGL.FX.Count)
	local now = CurTime()
	local C = ent.NGLLosCache
	if C then
		local x, y, z = from.x, from.y, from.z
		for i = 1, LOS_SLOTS do
			local e = C[i]
			if e and now - e.t < LOS_SHARE_TIME then
				local dx, dy, dz = e.x - x, e.y - y, e.z - z
				if dx * dx + dy * dy + dz * dz < LOS_SHARE_SQR then
					if losCount then losCount.losShared = (losCount.losShared or 0) + 1 end
					return e.vis
				end
			end
		end
	else
		C = { n = 0 }
		ent.NGLLosCache = C
	end
	local vis = lineOfSight(from, ent, npc)
	if losCount then losCount.losTraces = (losCount.losTraces or 0) + 1 end
	local k = C.n % LOS_SLOTS + 1
	C.n = k
	local e = C[k]
	if not e then
		e = {}
		C[k] = e
	end
	e.x, e.y, e.z, e.t, e.vis = from.x, from.y, from.z, now, vis
	return vis
end

-- Nearest hostile within sight, checking line of sight on at most the 3
-- closest candidates.
--
-- The grid is searched ring by ring outward from the NPC's own cell, and
-- stops as soon as no cell further out can hold anything closer than the 3
-- found (in a crowd that's the first ring or two instead of all 81 cells
-- of a 4000-unit sight range). Allies are skipped before any other check,
-- and positions come from the grid (each NPC's last think), not GetPos.
--
-- Shared sight (ngl_ai_share_sight): a squad or group leader searches a
-- little further and keeps the 6 nearest hostiles it found; members within
-- SHARE_RADIUS of it pick from that list for a second and a half instead of
-- searching the grid themselves. When the leader found nobody, nobody is
-- within sight of the members either, so they skip the search entirely.
local SHARE_RADIUS = 800
local SHARE_SQR = SHARE_RADIUS * SHARE_RADIUS
local SHARE_FOR = 1.5
local cand, candD = {}, {}
local nCand, nSlots = 0, 3
local eyeVec = Vector()

local function addCand(ent, d)
	local n = nCand
	if n < nSlots then
		n = n + 1
		nCand = n
		cand[n], candD[n] = ent, d
	elseif d < candD[n] then
		cand[n], candD[n] = ent, d
	else
		return
	end
	for i = n, 2, -1 do
		if candD[i] < candD[i - 1] then
			cand[i], cand[i - 1] = cand[i - 1], cand[i]
			candD[i], candD[i - 1] = candD[i - 1], candD[i]
		else
			break
		end
	end
end

local function scanCell(c, npc, pos, faction, rangeSqr)
	for ent in pairs(c) do
		-- Same faction is never hostile (NGL.GetRelation): no further checks.
		if ent ~= npc and ent.Faction ~= faction and Core.IsHostile(npc, ent) then
			local d = pos:DistToSqr(ent.NGLGridPos or ent:GetPos())
			if d <= rangeSqr then addCand(ent, d) end
		end
	end
end

local function scanAt(x, y, npc, pos, faction, rangeSqr)
	local c = cells[x * 4096 + y]
	if c then scanCell(c, npc, pos, faction, rangeSqr) end
end

local function findEnemy(npc, pos)
	local range = npc.SightRange
	local rangeSqr = range * range
	local faction = npc.Faction
	local now = CurTime()
	nCand, nSlots = 0, 3

	-- A member near its leader: the leader's list.
	local sq = npc.NGLSquad
	local leader = sq and sq.leader
	local shared = false
	if leader and leader ~= npc and cvShare:GetBool() and IsValid(leader) and leader.Faction == faction then
		local L = leader.NGLSight
		if L and now - L.t < SHARE_FOR and pos:DistToSqr(leader.NGLGridPos or leader:GetPos()) < SHARE_SQR then
			shared = true
			for i = 1, L.n do
				local ent = L[i]
				if IsValid(ent) and not ent.NGLDying and Core.IsHostile(npc, ent) then
					local d = pos:DistToSqr(ent:GetPos())
					if d <= rangeSqr then addCand(ent, d) end
				end
			end
		end
	end

	-- Leading others: search further, keep more, for the members.
	local leads = not shared and sq and leader == npc and #sq.members > 1 and cvShare:GetBool()
	local searchSqr = rangeSqr
	if leads then
		nSlots = 6
		searchSqr = (range + SHARE_RADIUS) ^ 2
	end

	if not shared then
		for i = 1, #players do
			local ply = players[i]
			if Core.IsHostile(npc, ply) then
				local d = pos:DistToSqr(ply:GetPos())
				if d <= searchSqr then addCand(ply, d) end
			end
		end
		local R = math.ceil(math.sqrt(searchSqr) / CELL)
		local cx, cy = floor(pos.x / CELL) + OFFSET, floor(pos.y / CELL) + OFFSET
		for k = 0, R do
			-- Everything in ring k is at least (k - 1) cells away.
			if nCand == nSlots and k > 1 and candD[nSlots] <= ((k - 1) * CELL) ^ 2 then break end
			if k == 0 then
				scanAt(cx, cy, npc, pos, faction, searchSqr)
			else
				for x = cx - k, cx + k do
					scanAt(x, cy - k, npc, pos, faction, searchSqr)
					scanAt(x, cy + k, npc, pos, faction, searchSqr)
				end
				for y = cy - k + 1, cy + k - 1 do
					scanAt(cx - k, y, npc, pos, faction, searchSqr)
					scanAt(cx + k, y, npc, pos, faction, searchSqr)
				end
			end
		end
		if leads then
			local L = npc.NGLSight or {}
			npc.NGLSight = L
			for i = 1, nCand do L[i] = cand[i] end
			for i = nCand + 1, L.n or 0 do L[i] = nil end
			L.n, L.t = nCand, now
		end
	end

	eyeVec:SetUnpacked(pos.x, pos.y, pos.z + npc.EyeHeight)
	local found, tried = nil, 0
	for i = 1, nCand do
		if not found and tried < 3 and candD[i] <= rangeSqr then
			tried = tried + 1
			if canSee(npc, eyeVec, cand[i]) then found = cand[i] end
		end
		cand[i] = nil
	end
	nCand = 0
	return found
end

-- Allies near `npc` with nothing to do come and look at `pos`.
local function alertAllies(npc, pos, now)
	local radius = npc.AlertRadius or 0
	if radius <= 0 or now < (npc.NGLNextAlert or 0) then return end
	npc.NGLNextAlert = now + 3
	local rSqr = radius * radius
	local myPos = npc:GetPos()
	local faction = npc.Faction
	local r = math.ceil(radius / CELL)
	local cx, cy = floor(myPos.x / CELL) + OFFSET, floor(myPos.y / CELL) + OFFSET
	for x = cx - r, cx + r do
		local base = x * 4096
		for y = cy - r, cy + r do
			local c = cells[base + y]
			if c then
				for ally in pairs(c) do
					if ally ~= npc and ally.NGLEnemy == nil and not ally.NGLInvestigate and not ally.NGLDying
						and NGL.GetRelation(faction, ally.Faction) == D_LI
						and myPos:DistToSqr(ally:GetPos()) < rSqr
						and ally:OnAlerted(npc, pos) ~= true then
						ally.NGLInvestigate = pos
						ally.NGLInvestigateUntil = now + 20
						Core.Wake(ally)
					end
				end
			end
		end
	end
end

-- Pushing: NGL NPCs don't collide with each other (COLLISION_GROUP_NPC_SCRIPTED,
-- see ENT:Initialize), so nobody blocks anybody's path and nobody has to
-- find a new one. Instead an NPC walking into another one pushes it aside:
-- the one in front gets a shove (NGLShove, moved a few units every tick by
-- BehaveUpdate, see Core.ShoveStep) away from the walker's line and a little
-- forward. The walker keeps its path and speed. Only when it's catching up
-- (faster than the other one moves away). Uses the spatial grid and
-- positions from each NPC's last think: no extra traces.
local PUSH_LOOK = 24          -- how far past touching we look ahead
local SHOVE_TIME = 0.3        -- a shove lasts this long, renewed while touching
local function radiusOf(e)
	local r = e.NGLRadius
	if r then return r end
	local h = e.Hull
	return h and h[2].x or 18
end

local function idOf(e) return e.EntIndex and e:EntIndex() or tonumber(tostring(e):match("0x(%x+)") or "0", 16) or 0 end

local function speedOf(e)
	local l = e.loco
	local v = l and l.GetVelocity and l:GetVelocity()
	if not v then return 0, 0 end
	return v.x or 0, v.y or 0
end

local function shove(e, x, y, speed, now)
	if e.IsVehicleNPC or e.NGLTraverse or e.NGLDying then return end
	local sh = e.NGLShove
	if sh then
		if now < sh.untilT and sh.speed > speed then return end -- a harder shove wins
	else
		-- One table per NPC, kept and refilled: in a crowd every think
		-- shoves several neighbours, and a new table for each was a large
		-- part of the garbage.
		sh = e.NGLShoveT or {}
		e.NGLShoveT = sh
		e.NGLShove = sh
	end
	sh.x, sh.y, sh.speed, sh.untilT = x, y, speed, now + SHOVE_TIME
end
Core.Shove = shove

local function pushCheck(npc, now, pos)
	local g = npc.NGLSteer
	if not (g and npc.NGLMoving) or npc.IsVehicleNPC then return end
	local dx, dy = g.x - pos.x, g.y - pos.y
	local l = math.sqrt(dx * dx + dy * dy)
	if l < 8 then return end
	dx, dy = dx / l, dy / l
	local vx, vy = speedOf(npc)
	local mySpeed = vx * dx + vy * dy
	if mySpeed < 30 then mySpeed = npc.NGLMoveMode == "walk" and 90 or 180 end -- just starting
	local myR = radiusOf(npc)
	local reach = myR + 40 + PUSH_LOOK
	local x0, x1 = floor((pos.x - reach) / CELL) + OFFSET, floor((pos.x + reach) / CELL) + OFFSET
	local y0, y1 = floor((pos.y - reach) / CELL) + OFFSET, floor((pos.y + reach) / CELL) + OFFSET
	for x = x0, x1 do
		local base = x * 4096
		for y = y0, y1 do
			local c = cells[base + y]
			if c then
				for e in pairs(c) do
					local p = e.NGLGridPos
					if p and e ~= npc and not e.NGLDying and not e.IsVehicleNPC and abs(p.z - pos.z) < 64 then
						local ox, oy = p.x - pos.x, p.y - pos.y
						local along = ox * dx + oy * dy
						local w = myR + radiusOf(e)
						if along > -w * 0.5 and along < w + PUSH_LOOK then
							local side = oy * dx - ox * dy -- > 0: left of our line
							if side < w and side > -w then
								-- Catching up with it?
								local ex, ey = speedOf(e)
								local closing = mySpeed - (ex * dx + ey * dy)
								if closing > 20 then
									-- Off our line, to whichever side it's on (right on
									-- it: our right, so two meeting head on pass).
									local s
									if side > 2 then s = 1 else s = -1 end
									local px, py = -dy * s * 0.85 + dx * 0.5, dx * s * 0.85 + dy * 0.5
									local pl = math.sqrt(px * px + py * py)
									shove(e, px / pl, py / pl, math.min(closing, 220), now)
								end
							end
						end
					end
				end
			end
		end
	end
end
Core.PushCheck = pushCheck

-- Standing inside each other (sidestepping in a fight, two walking to the
-- same spot): both are shoved apart, slowly, until they're clear. Nobody's
-- path or goal changes. Positions from the spatial grid.
local OVERLAP_SPEED = 70
-- Walls, props and players stop a shove; other NGL NPCs (their collision
-- group) don't.
local nudgeTrace = { mask = MASK_NPCSOLID, collisiongroup = COLLISION_GROUP_NPC_SCRIPTED, output = {} }
local nudgeFilter = {}

-- The hull, read once per NPC (it's set once, in ENT:Initialize). The
-- engine hands back two new vectors on every call.
local DEFAULT_MINS, DEFAULT_MAXS = Vector(-16, -16, 0), Vector(16, 16, 72)
local function boundsOf(npc)
	local mins = npc.NGLMins
	if mins then return mins, npc.NGLMaxs end
	local maxs
	if npc.GetCollisionBounds then mins, maxs = npc:GetCollisionBounds() end
	mins, maxs = mins or DEFAULT_MINS, maxs or DEFAULT_MAXS
	npc.NGLMins, npc.NGLMaxs = mins, maxs
	return mins, maxs
end
Core.BoundsOf = boundsOf

-- Scratch vectors for trace starts and ends: a trace reads them when it's
-- called and keeps nothing, so a few shared ones do instead of new ones
-- for every trace.
local vA, vB, vC = Vector(), Vector(), Vector()

-- Moves npc from pos to (x, y, z) if its hull fits all the way (world
-- only). Its new position goes in a vector of its own, refilled each time
-- (NGLGridPos while it lasts; nothing else keeps it).
local function slideTo(npc, pos, x, y, z)
	local t = nudgeTrace
	vA:SetUnpacked(pos.x, pos.y, pos.z + 4)
	vB:SetUnpacked(x, y, z + 4)
	t.start, t.endpos = vA, vB
	t.mins, t.maxs = boundsOf(npc)
	local ig = npc.NGLShoveIgnore -- the player it is stepping out of
	if ig and IsValid(ig) then
		nudgeFilter[1], nudgeFilter[2] = npc, ig
		t.filter = nudgeFilter
	else
		t.filter = npc
	end
	local tr = util.TraceHull(t)
	nudgeFilter[1], nudgeFilter[2] = nil, nil
	if tr.Hit or tr.StartSolid then return nil end
	local to = npc.NGLSlidPos
	if not to then
		to = Vector()
		npc.NGLSlidPos = to
	end
	to:SetUnpacked(x, y, z)
	npc:SetPos(to)
	npc.NGLGridPos = to
	return to
end

-- One tick of a shove (BehaveUpdate): moved `interval` seconds' worth, if
-- there's room. Returns the new position, or nil when it's over or blocked.
-- The vector returned is refilled by the next shove: read it, don't keep it.
function Core.ShoveStep(npc, pos, interval, now)
	local sh = npc.NGLShove
	if not sh then return nil end
	if now >= sh.untilT or npc.IsVehicleNPC then npc.NGLShove, npc.NGLShoveIgnore = nil, nil return nil end
	local step = sh.speed * math.min(interval or 0.015, 0.1)
	if step < 0.5 then return nil end
	local to = slideTo(npc, pos, pos.x + sh.x * step, pos.y + sh.y * step, pos.z)
	if to then return to end
	npc.NGLShove, npc.NGLShoveIgnore = nil, nil -- against a wall: stays where it is
	return nil
end

-- The way a is pushed away from b: straight apart, or, right on top of each
-- other, a way both of them agree on (from their entity numbers).
local function apartDir(a, apos, b, bpos)
	local x, y = apos.x - bpos.x, apos.y - bpos.y
	local d = math.sqrt(x * x + y * y)
	if d >= 1 then return x / d, y / d end
	local ia, ib = idOf(a), idOf(b)
	local ang = math.min(ia, ib) * 2.39996 -- golden angle: neighbours spread out
	local sx = ia < ib and 1 or -1
	return math.cos(ang) * sx, math.sin(ang) * sx
end
Core.ApartDir = apartDir

local SEP_TIME = 0.35
local function overlapCheck(npc, now, pos)
	if npc.IsVehicleNPC then return end
	local myR = radiusOf(npc)
	local sx, sy = 0, 0
	local reach = myR + 40
	local x0, x1 = floor((pos.x - reach) / CELL) + OFFSET, floor((pos.x + reach) / CELL) + OFFSET
	local y0, y1 = floor((pos.y - reach) / CELL) + OFFSET, floor((pos.y + reach) / CELL) + OFFSET
	for x = x0, x1 do
		local base = x * 4096
		for y = y0, y1 do
			local c = cells[base + y]
			if c then
				for e in pairs(c) do
					local p = e.NGLGridPos
					if p and e ~= npc and not e.NGLDying and not e.IsVehicleNPC and abs(p.z - pos.z) < 64 then
						local ox, oy = pos.x - p.x, pos.y - p.y
						local gap = math.sqrt(ox * ox + oy * oy) - myR - radiusOf(e)
						if gap < -2 then
							local bx, by = apartDir(npc, pos, e, p)
							-- Running into each other (a pack going for the
							-- same target): a shove alone loses to their
							-- running, so harder, and they steer apart too.
							local moving = npc.NGLMoving or e.NGLMoving
							local sp = math.min(moving and 200 or OVERLAP_SPEED, 20 - gap * (moving and 8 or 3))
							shove(npc, bx, by, sp, now)
							shove(e, -bx, -by, sp, now)
							sx, sy = sx - bx * gap, sy - by * gap
						end
					end
				end
			end
		end
	end
	if sx ~= 0 or sy ~= 0 then
		local l = math.sqrt(sx * sx + sy * sy)
		local S = npc.NGLSepT or {}
		npc.NGLSepT = S
		S.x, S.y, S.untilT = sx / l, sy / l, now + SEP_TIME
		npc.NGLSep = S
	end
end

-- Shortcuts: on patchy ground (hills, rubble) the grid's path zig-zags from
-- point to point. Every SHORTCUT_EVERY seconds an NPC on a path checks if it
-- can walk straight past its next waypoint to one further on (the furthest
-- of SHORTCUT_AHEAD): one hull trace from here to there, and the ground under
-- the line every SHORTCUT_SAMPLE units (no hole, no drop, nothing steeper
-- than a slope a NextBot walks up). Never past a jump, drop or climb on the
-- path, nor across floors.
local SHORTCUT_EVERY = 0.4
local SHORTCUT_AHEAD = 3
local SHORTCUT_MAX = 600        -- no further than this in one go
local SHORTCUT_SAMPLE = 32
local SHORT_STEP = NGL.StepHeight or 26
local cutHull = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }
local cutDown = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }

function Core.WalkClear(npc, from, to)
	local dx, dy = to.x - from.x, to.y - from.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1 then return true end
	if len > SHORTCUT_MAX or abs(to.z - from.z) > len + SHORT_STEP then return false end
	local t = cutHull
	vA:SetUnpacked(from.x, from.y, from.z + SHORT_STEP)
	vB:SetUnpacked(to.x, to.y, to.z + SHORT_STEP)
	t.start, t.endpos = vA, vB
	local mins, maxs = boundsOf(npc)
	vC:SetUnpacked(maxs.x, maxs.y, math.max(maxs.z - SHORT_STEP, 8))
	t.mins, t.maxs = mins, vC
	t.filter = npc
	local tr = util.TraceHull(t)
	if tr.Hit or tr.StartSolid then return false end
	-- The ground all the way: each sample near where the slope so far says.
	local n = math.max(1, math.ceil(len / SHORTCUT_SAMPLE))
	local seg = len / n
	local pz = from.z
	local d = cutDown
	d.filter = npc
	for k = 1, n - 1 do
		local f = k / n
		local x, y = from.x + dx * f, from.y + dy * f
		vA:SetUnpacked(x, y, pz + SHORT_STEP + seg + 8)
		vB:SetUnpacked(x, y, pz - SHORT_STEP - seg - 8)
		d.start, d.endpos = vA, vB
		local g = util.TraceLine(d)
		if not g.Hit or g.StartSolid then return false end
		local hn = g.HitNormal
		if hn and hn.z and hn.z < 0.7 then return false end
		pz = g.HitPos.z
	end
	return abs(to.z - pz) <= SHORT_STEP + seg
end

function Core.Shortcut(npc, now, pos)
	local path = npc.NGLPath
	if not path or npc.NGLTraverse or npc.IsVehicleNPC or npc.NavWidth then return end
	if now < (npc.NGLShortcutAt or 0) then return end
	npc.NGLShortcutAt = now + SHORTCUT_EVERY
	local idx = npc.NGLPathIdx or 1
	local links = path.links
	local last = idx
	for k = idx, math.min(#path - 1, idx + SHORTCUT_AHEAD - 1) do
		if links and links[k] then break end -- a jump or climb from waypoint k: stop there
		last = k + 1
	end
	for k = last, idx + 1, -1 do
		if Core.WalkClear(npc, pos, path[k]) then
			npc.NGLPathIdx = k
			return k
		end
	end
end

-- Just spawned on top of another NGL NPC (the spawn menu, a squad or a
-- dropship all on one spot): moved to the nearest free spot round it, with
-- room for its hull and ground under it. Once, on its first think.
local PLACE_RINGS = { 40, 72, 108 }
local placeDown = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }
local function freeSpot(npc, p, myR)
	for _, e in ipairs(Core.FindInRadius(p, myR + 18 + 2)) do
		if e ~= npc and not e.IsVehicleNPC then return false end
	end
	return true
end
function Core.PlaceFree(npc, pos)
	if npc.IsVehicleNPC then return end
	local myR = radiusOf(npc)
	if freeSpot(npc, pos, myR) then return end
	local a0 = (idOf(npc) % 8) * math.pi / 4
	for _, r in ipairs(PLACE_RINGS) do
		for k = 0, 7 do
			local a = a0 + k * math.pi / 4
			local to = Vector(pos.x + math.cos(a) * r, pos.y + math.sin(a) * r, pos.z)
			if freeSpot(npc, to, myR) then
				local d = placeDown
				d.start, d.endpos = to + Vector(0, 0, 24), to - Vector(0, 0, 48)
				d.filter = npc
				local g = util.TraceLine(d)
				if g.Hit and not g.StartSolid and slideTo(npc, pos, to.x, to.y, g.HitPos.z) then return end
			end
		end
	end
end
Core.OverlapCheck = overlapCheck

-- Stuck walking into something: one hull trace the way we walk; if it hits a
-- wall, steer along it (to the side nearer where we're going) and a little
-- away from it for a moment (NGLUnstick), which gets round a door frame.
local SLIDE_AFTER = 1
local wallTrace = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }
function Core.SlideAlongWall(npc, now, pos)
	local g = npc.NGLSteer or npc.NGLGoal
	if not g then return false end
	local dx, dy = g.x - pos.x, g.y - pos.y
	local l = math.sqrt(dx * dx + dy * dy)
	if l < 1 then return false end
	dx, dy = dx / l, dy / l
	local t = wallTrace
	vA:SetUnpacked(pos.x, pos.y, pos.z + 20)
	vB:SetUnpacked(pos.x + dx * 32, pos.y + dy * 32, pos.z + 20)
	t.start, t.endpos = vA, vB
	local mins, maxs = boundsOf(npc)
	vC:SetUnpacked(maxs.x, maxs.y, math.max(maxs.z - 20, 8))
	t.mins, t.maxs = mins, vC
	t.filter = npc
	local tr = util.TraceHull(t)
	local hn = tr.HitNormal
	if not tr.Hit or tr.StartSolid or not hn then return false end
	local nx, ny = hn.x, hn.y
	local nl = math.sqrt(nx * nx + ny * ny)
	if nl < 0.3 then return false end -- the floor or a slope, not a wall
	nx, ny = nx / nl, ny / nl
	local tx, ty = -ny, nx
	if tx * dx + ty * dy < 0 then tx, ty = -tx, -ty end
	local sx, sy = tx * 0.8 + nx * 0.6, ty * 0.8 + ny * 0.6
	local sl = math.sqrt(sx * sx + sy * sy)
	if sl < 0.01 then return false end
	local U = npc.NGLUnstickT or {}
	npc.NGLUnstickT = U
	U.x, U.y, U.untilT = sx / sl, sy / sl, now + 0.7
	npc.NGLUnstick = U
	return true
end

-- NGL NPCs within `radius` of `pos` for which `filter(npc)` is true (all
-- if no filter). Uses the spatial grid, so it only looks at nearby cells.
function Core.FindInRadius(pos, radius, filter)
	local out = {}
	local rSqr = radius * radius
	local r = math.ceil(radius / CELL)
	local cx, cy = floor(pos.x / CELL) + OFFSET, floor(pos.y / CELL) + OFFSET
	for x = cx - r, cx + r do
		local base = x * 4096
		for y = cy - r, cy + r do
			local c = cells[base + y]
			if c then
				for ent in pairs(c) do
					if not ent.NGLDying and pos:DistToSqr(ent:GetPos()) <= rSqr and (not filter or filter(ent)) then
						out[#out + 1] = ent
					end
				end
			end
		end
	end
	return out
end
NGL.FindInRadius = Core.FindInRadius

-- Is any NGL NPC other than `except` (and not a vehicle) within `radius`
-- of (x, y, z)? The grid, positions from each NPC's last think, and no
-- table made: for checks that only need a yes or no.
function Core.AnyNear(x, y, z, radius, except)
	local rSqr = radius * radius
	local r = math.ceil(radius / CELL)
	local cx, cy = floor(x / CELL) + OFFSET, floor(y / CELL) + OFFSET
	for gx = cx - r, cx + r do
		local base = gx * 4096
		for gy = cy - r, cy + r do
			local c = cells[base + gy]
			if c then
				for ent in pairs(c) do
					if ent ~= except and not ent.NGLDying and not ent.IsVehicleNPC then
						local p = ent.NGLGridPos or ent:GetPos()
						local dx, dy, dz = p.x - x, p.y - y, p.z - z
						if dx * dx + dy * dy + dz * dz <= rSqr then return true end
					end
				end
			end
		end
	end
	return false
end

-- Eye height, lower while crouched.
local function eyeHeight(npc)
	return npc.NGLCrouch and npc.CrouchEyeHeight or npc.EyeHeight
end
Core.EyeHeight = eyeHeight

function Core.CanSee(npc, ent)
	local from = npc:GetPos()
	from.z = from.z + eyeHeight(npc)
	return canSee(npc, from, ent)
end
Core.FindEnemy = findEnemy

function Core.SetEnemy(npc, enemy)
	local old = npc.NGLEnemy
	if old == enemy then return end
	local now = CurTime()
	npc.NGLEnemy = enemy
	npc.NGLFireAccum = 0
	if npc.NGLSlotTarget and npc.NGLSlotTarget ~= enemy then Core.ReleaseSlot(npc) end
	npc.NGLPath = nil
	npc.NGLPathPending = false
	npc.NGLPathReq = (npc.NGLPathReq or 0) + 1 -- a path to the old enemy is no use
	npc.NGLEnemyVisible = true -- found by sight (or it just shot us); rechecked shortly
	npc.NGLNextVis = now + 0.5
	if IsValid(enemy) then
		local ePos = enemy:GetPos()
		npc.NGLLastSeenPos, npc.NGLLastSeenT = ePos, now
		npc.NGLInvestigate = nil
		npc:NGLSetMoveMode("run")
		if not IsValid(old) then
			npc.NGLContactPos = npc:GetPos() -- where the fight started (defenders hold it)
			alertAllies(npc, ePos, now)
			if npc.NGLSquad then npc.NGLSquad:Contact(npc, ePos, now) end
			npc:NGLSound("Alert")
		end
		npc:OnSeeEnemy(enemy)
	else
		npc.NGLEnemy = nil
		npc.NGLGoal = nil
		npc.NGLFace = nil
		npc.NGLHome = npc:GetPos() -- wander around where the fight ended
		npc.NGLNextWander = now + Rand(1, 3)
		if IsValid(old) then
			npc:NGLSound(old:Health() > 0 and "Lost" or "Kill")
			npc:OnLoseEnemy(old)
		end
	end
end

----------------------------------------------------------------------------
-- Combat
----------------------------------------------------------------------------

-- The silent shot hits bounding boxes, not hitboxes: a trace through
-- hitboxes makes the server set up the bones of every NPC it passes, one
-- of the dearest calls per NPC, and the silent shot's damage is an average
-- anyway. Real bullets near players still hit hitboxes.
local SILENT_MASK = bit.band(MASK_SHOT, bit.bnot(CONTENTS_HITBOX))
Core.SilentMask = SILENT_MASK
local shotTrace = { mask = SILENT_MASK }
local SHOT_PAST = 48 -- the silent shot's trace goes this far past the aim point
local shotResult = {}
shotTrace.output = shotResult

-- Deals damage from an NGL NPC (melee hits, custom attacks).
function Core.Damage(attacker, target, amount, dmgType, pos, force)
	if NGL.Off.damage and NGL.IsOff(attacker, "damage") then return end -- ngl_debug_parts
	local dmg = DamageInfo()
	dmg:SetDamage(amount)
	dmg:SetDamageType(dmgType or DMG_GENERIC)
	dmg:SetAttacker(attacker)
	dmg:SetInflictor(attacker)
	dmg:SetDamagePosition(pos or target:WorldSpaceCenter())
	if force then dmg:SetDamageForce(force) end
	target:TakeDamageInfo(dmg)
end

-- `enemy` may be nil when shooting at an area (`dst`, e.g. a fire_at order).
-- ENT:NGLMuzzle() (optional) returns where shots start and the attachment
-- for the muzzle flash, e.g. a vehicle's gun barrel.
-- Shots are the most frequent thing NPCs do in a firefight, so they reuse
-- their vectors and bullet table: FireBullets, effects and traces read them
-- when called and keep nothing.
local fireDir, fireEnd = Vector(), Vector()
local bullet = {}
local function spreadOf(w)
	local v = w.NGLSpreadVec
	if not v or w.NGLSpreadOf ~= w.Spread then
		v = Vector(w.Spread, w.Spread, 0)
		w.NGLSpreadVec, w.NGLSpreadOf = v, w.Spread
	end
	return v
end

local function fire(npc, enemy, shots, visual, dst)
	local w = npc.Weapon
	local src, att
	if visual and npc.NGLMuzzle then src, att = npc:NGLMuzzle() end
	if not src then
		src = npc:GetPos()
		src.z = src.z + eyeHeight(npc)
	end
	dst = dst or enemy:WorldSpaceCenter()

	-- Projectile weapon (rockets, grenades...): see sv_projectile.lua.
	if w.Projectile then
		if visual then
			npc:NGLGesture("Fire")
			if w.Sound then npc:EmitSound(w.Sound) end
		end
		for _ = 1, shots do NGL.Proj.Fire(npc, w.Projectile, src, dst, visual) end
		return
	end

	if visual then
		npc:NGLGesture("Fire")
		local dir = fireDir
		dir:Set(dst)
		dir:Sub(src)
		dir:Normalize()
		-- Tracers and impacts thinned out away from players (sv_fx.lua).
		local b = bullet
		b.Src, b.Dir, b.Spread, b.Num, b.Damage = src, dir, spreadOf(w), shots, w.Damage
		b.Tracer, b.TracerName, b.Attacker, b.IgnoreEntity, b.Callback = 1, w.Tracer, npc, npc, nil
		npc:FireBullets(NGL.FX.Bullet(npc, b, src))
		b.Attacker, b.IgnoreEntity, b.Callback = nil, nil, nil
		if w.MuzzleEffect then
			local ed = EffectData()
			ed:SetEntity(npc)
			ed:SetAttachment(att or 1)
			ed:SetOrigin(src)
			ed:SetAngles(dir:Angle())
			ed:SetScale(1)
			NGL.FX.Muzzle(w.MuzzleEffect, ed, src)
		end
		if w.Sound then npc:EmitSound(w.Sound) end
		return
	end

	-- Nobody close enough to see it: one silent trace, expected damage.
	-- It goes on a little past the aim point: a trace that stops exactly at
	-- the target's middle missed small or hunched models (headcrabs, fast
	-- zombies), whose hitboxes don't reach their box's centre, so they
	-- never took damage in battles away from players. Reaching the aim
	-- point with nothing in the way counts as a hit too.
	local dir = fireDir
	dir:Set(dst)
	dir:Sub(src)
	local len = dir:Length()
	if len > 1 then dir:Mul(1 / len) end
	fireEnd:Set(dir)
	fireEnd:Mul(SHOT_PAST)
	fireEnd:Add(dst)
	shotTrace.start = src
	shotTrace.endpos = fireEnd
	shotTrace.filter = npc
	util.TraceLine(shotTrace)
	local hit = shotResult.Entity
	if enemy and hit ~= enemy and shotResult.Fraction * (len + SHOT_PAST) >= len - 4 then
		hit = enemy -- nothing before the aim point: it was inside the target's box
		shotResult.HitPos = dst
	end
	if enemy and hit == enemy or not enemy and IsValid(hit) and (hit:IsPlayer() or hit.IsNGLNPC) and Core.IsHostile(npc, hit) then
		local dmg = DamageInfo()
		dmg:SetDamage(w.Damage * shots * (w.Accuracy or 0.6))
		dmg:SetDamageType(DMG_BULLET)
		dmg:SetAttacker(npc)
		dmg:SetInflictor(npc)
		dmg:SetDamagePosition(shotResult.HitPos)
		hit:TakeDamageInfo(dmg)
	end
end

Core.Fire = fire

-- Ranged attack for this think: fires the shots owed since the last one
-- (far NPCs think rarely but deal the same damage over time), handles the
-- clip and reload. `enemy` may be nil with `dst` set to shoot at an area.
local FIRE_CONE = math.cos(math.rad(50)) -- fires at what is within this angle of where it faces
local function shoot(npc, now, dt, enemy, dst)
	local w = npc.Weapon
	if not w then return end
	if now < (npc.NGLReloadUntil or 0) then
		npc.NGLFireAccum = 0
		return
	end
	local acc = (npc.NGLFireAccum or 0) + dt
	local shots = floor(acc / w.Delay)
	if shots <= 0 then
		npc.NGLFireAccum = acc
		return
	end
	npc.NGLFireAccum = acc - shots * w.Delay
	-- Only at what's in front of it. A soldier running one way with the
	-- enemy behind it shot backwards out of a gun pointing forwards (the
	-- run faces where it goes, see BehaveUpdate). It holds fire until it
	-- has turned (walking and standing NPCs turn to the target at once).
	-- Vehicles aim their own turrets; ENT.FireAnyDirection lets others too.
	-- Only where a player can see it: further out NPCs face where they walk
	-- even while strafing (see BehaveUpdate), and nobody sees the gun.
	if npc.NGLNear and not (npc.IsVehicleNPC or npc.FireAnyDirection) then
		local p = npc:GetPos()
		local t = dst or enemy:GetPos()
		local dx, dy = t.x - p.x, t.y - p.y
		local l = math.sqrt(dx * dx + dy * dy)
		if l > 24 then
			local r = math.rad(npc:GetAngles().y)
			if (dx * math.cos(r) + dy * math.sin(r)) / l < FIRE_CONE then
				npc.NGLFireAccum = 0
				return
			end
		end
	end
	if npc:OnAttack(enemy or dst, "ranged") == true then return end

	local clipSize = w.Clip or 0
	if clipSize > 0 then
		shots = min(shots, npc.NGLClip)
		npc.NGLClip = npc.NGLClip - shots
	end
	-- Real bullets only where a player may see them. Near but out of every
	-- player's sight (behind a wall): the silent trace, with the gun's sound
	-- so the fight is still heard. Projectiles keep flying near players
	-- either way (they can come round a corner).
	local visual = npc.NGLNear and (npc.NGLSeen ~= false or w.Projectile ~= nil)
	if shots > 0 then
		fire(npc, enemy, min(shots, visual and 3 or 30), visual, dst)
		if not visual and npc.NGLNear and w.Sound then npc:EmitSound(w.Sound) end
	end

	if clipSize > 0 and npc.NGLClip <= 0 then
		npc.NGLClip = clipSize
		npc.NGLReloadUntil = now + (w.ReloadTime or 2)
		npc.NGLFireAccum = 0
		npc:NGLGesture("Reload")
		npc:NGLSound("Reload")
		npc:OnReload()
	end
end
Core.Shoot = shoot

----------------------------------------------------------------------------
-- Melee
----------------------------------------------------------------------------

local function pick(s)
	if type(s) == "table" then return s[random(#s)] end
	return s
end

local cvMeleeDebug = CreateConVar("ngl_debug_melee", "0", FCVAR_NONE, "Print each melee swing's animation and when its blows land.", 0, 1)

-- Starts a swing at `target`. The blow lands HitDelay seconds later (the NPC
-- thinks again right then), if the target is still in reach and in front.
function Core.StartMelee(npc, target, now)
	local m = npc.Melee
	if not m or not IsValid(target) then return false end
	npc.NGLNextMelee = now + (m.Delay or 1.5)
	npc.NGLMeleeTarget = target
	Core.StopMoving(npc)
	npc.NGLCrouch = false
	npc.NGLFace = target:GetPos()
	local played, seq = npc:NGLPlayMeleeAnim()
	local dur = played or m.Duration or 1
	-- When the blows land: on the animation's own hit events when the model
	-- has them (each one a blow, like HL2's zombies), else after HitDelay.
	local times = played and m.UseEvents ~= false and npc.NGLHitTimes and npc:NGLHitTimes(seq, played)
	if times and #times > 0 then
		-- The engine hands this NPC its hit events as they play
		-- (ENT:HandleAnimEvent): they land the blows; these times are
		-- only a fallback, a little later, if one goes missing.
		local late = npc.NGLLiveHits and 0.35 or 0
		npc.NGLMeleeHitAt = now + times[1] + late
		local rest = {}
		for k = 2, #times do rest[#rest + 1] = now + times[k] + late end
		npc.NGLMeleeMore = #rest > 0 and rest or nil
	elseif type(m.HitDelay) == "table" then -- several blows: { 0.2, 0.45 }
		npc.NGLMeleeHitAt = now + (m.HitDelay[1] or 0.4)
		local rest = {}
		for k = 2, #m.HitDelay do rest[#rest + 1] = now + m.HitDelay[k] end
		npc.NGLMeleeMore = #rest > 0 and rest or nil
	else
		npc.NGLMeleeHitAt = now + (m.HitDelay or 0.4)
		npc.NGLMeleeMore = nil
	end
	npc.NGLBusyUntil = max(npc.NGLBusyUntil or 0, now + dur)
	if cvMeleeDebug:GetBool() then
		local list = {}
		local at = npc.NGLMeleeHitAt
		list[1] = string.format("%.2f", at - now)
		for _, t in ipairs(npc.NGLMeleeMore or {}) do list[#list + 1] = string.format("%.2f", t - now) end
		print(string.format("[NGL] %s swing %s (%.2f s): blows at %s s (%s)", npc:GetClass(),
			seq and npc:GetSequenceName(seq) or "?", dur, table.concat(list, ", "),
			(times and #times > 0) and "model events" or "Melee.HitDelay"))
	end
	npc:NGLSound("Attack")
	if npc.NGLNextThink and npc.NGLNextThink > npc.NGLMeleeHitAt then npc.NGLNextThink = npc.NGLMeleeHitAt end
	return true
end

local function resolveMelee(npc)
	local m = npc.Melee
	local t = npc.NGLMeleeTarget
	npc.NGLMeleeHitAt, npc.NGLMeleeTarget = nil, nil
	if not m or not IsValid(t) or (t.NGLDying) then npc.NGLMeleeMore = nil return end
	-- More blows in this swing (left claw, right claw): the next one.
	local more = npc.NGLMeleeMore
	if more then
		npc.NGLMeleeHitAt = table.remove(more, 1)
		npc.NGLMeleeTarget = t
		if #more == 0 then npc.NGLMeleeMore = nil end
		if npc.NGLNextThink and npc.NGLNextThink > npc.NGLMeleeHitAt then npc.NGLNextThink = npc.NGLMeleeHitAt end
	end

	local pos, tPos = npc:GetPos(), t:GetPos()
	local reach = (m.Range or 70) * 1.3
	local to = tPos - pos
	local hit = to:LengthSqr() <= reach * reach and abs(to.z) < 80
	if hit then
		to.z = 0
		to:Normalize()
		hit = to:Dot(npc:GetForward()) > 0.3
	end
	if hit then
		Core.Damage(npc, t, m.Damage or 10, m.DamageType or DMG_SLASH, t:WorldSpaceCenter(), to * (m.Force or 0))
		if m.HitSound and npc.NGLNear then npc:EmitSound(pick(m.HitSound)) end
	elseif m.MissSound and npc.NGLNear then
		npc:EmitSound(pick(m.MissSound))
	end
	npc:OnMeleeHit(t, hit)
end
Core.ResolveMelee = resolveMelee

local ATTACK_KEEP_SQR_PAD = 1.2 * 1.2
local STUCK_SQR = 16 * 16
local REPATH_SQR = 300 * 300
local PATH_TIMEOUT = 3   -- s to wait for a path before walking straight
local FAIL_BACKOFF = 3   -- s of walking straight after a failed request
local FORCE_PATH = 5     -- s of path-only movement after getting stuck going straight

-- Index of the nearest of the first few waypoints. Paths are shared by NPCs
-- that started near each other, so ours may begin a few cells away.
local function firstWaypoint(path, pos)
	local best, bestD = 1, math.huge
	for k = 1, min(#path, 4) do
		local d = pos:DistToSqr(path[k])
		if d < bestD then best, bestD = k, d end
	end
	-- Standing on it already: aim for the next one.
	if bestD < 64 * 64 and best < #path then best = best + 1 end
	return best
end

-- Can we walk straight there? Asked of the nav grid (table lookups, no
-- traces), at most once a second per NPC unless the target moves: a ledge,
-- wall or drop in the way means taking a path round it instead.
local LINE_RECHECK_SQR = 64 * 64
local LINE_CHECK_DIST = 1200
local function straightOk(npc, now, pos, tPos)
	local c = npc.NGLLineCheck
	if c and now < c.t and (c.x - tPos.x) ^ 2 + (c.y - tPos.y) ^ 2 < LINE_RECHECK_SQR then return c.ok end
	c = c or {}
	c.t, c.x, c.y = now + 1, tPos.x, tPos.y
	-- Only the next stretch: what's beyond is checked as we get closer.
	local dx, dy = tPos.x - pos.x, tPos.y - pos.y
	local d = math.sqrt(dx * dx + dy * dy)
	local to, zTol = tPos, nil
	if d > LINE_CHECK_DIST then
		local f = LINE_CHECK_DIST / d
		to = Vector(pos.x + dx * f, pos.y + dy * f, pos.z + (tPos.z - pos.z) * f)
		zTol = 96 -- only a guess at the height half way
	end
	c.ok = NGL.Nav.WalkLine(pos, to, zTol) ~= false
	npc.NGLLineCheck = c
	return c.ok
end

-- Squad path sharing: a squad member going where its leader's path goes
-- (the same target, give or take) joins that path at the point nearest it
-- instead of searching its own. Paths are never changed once made, so the
-- same table is shared. Only with the same jumps and width as the leader,
-- on the same floor, within SHARE_JOIN of the path, and with the grid saying
-- it can walk straight to where it joins.
local SHARE_JOIN = 160
local function sharedPath(npc, pos, tPos)
	local sq = npc.NGLSquad
	local L = sq and sq.leader
	if not L or L == npc or not IsValid(L) or L.NGLDying then return nil end
	local path, tgt = L.NGLPath, L.NGLPathTarget
	if not path or not tgt or tgt:DistToSqr(tPos) > REPATH_SQR then return nil end
	if (npc.NavWidth or 0) ~= (L.NavWidth or 0) or npc.NGLNavCaps ~= L.NGLNavCaps then return nil end
	local best, bd
	for k = math.max(1, (L.NGLPathIdx or 1) - 2), #path do
		local p = path[k]
		if abs(p.z - pos.z) < 64 then
			local d = (p.x - pos.x) ^ 2 + (p.y - pos.y) ^ 2
			if d < SHARE_JOIN * SHARE_JOIN and (not bd or d < bd) then best, bd = k, d end
		end
	end
	if not best then return nil end
	local nav = NGL.Nav
	if nav.WalkLine and nav.WalkLine(pos, path[best]) == false then return nil end
	return path, best, tgt
end
Core.SharedPath = sharedPath

-- Move towards the enemy. Straight line when it's in view on the same level
-- and the grid says nothing's in the way (no path-finding at all), otherwise
-- along a path from our nav grid, requested in the background. The NPC never
-- stands still waiting: until the path arrives (or if it fails) it keeps
-- walking straight at the target.
local function chase(npc, now, pos, tPos, visible)
	local nav = NGL.Nav
	local forcePath = now < (npc.NGLForcePathUntil or 0)
	if not (nav and nav.Loaded) or now < (npc.NGLPathFailUntil or 0)
		or (visible and not forcePath and abs(tPos.z - pos.z) < 96 and straightOk(npc, now, pos, tPos)) then
		npc.NGLPath = nil
		npc.NGLGoal = tPos
		npc.NGLDirect = true
		return
	end
	npc.NGLDirect = false

	-- Waiting for a path: keep moving, give up after PATH_TIMEOUT.
	if npc.NGLPathPending then
		if now - npc.NGLPathPendingSince > PATH_TIMEOUT then
			npc.NGLPathPending = false
			npc.NGLPathReq = npc.NGLPathReq + 1 -- the late answer is ignored
			npc.NGLPathFailUntil = now + FAIL_BACKOFF
			npc.NGLGoal = tPos
		elseif not npc.NGLPath then
			npc.NGLGoal = (not forcePath) and tPos or nil
		end
		return
	end

	-- Keep the current path while the enemy hasn't moved far from its end.
	local tgt = npc.NGLPathTarget
	if npc.NGLPath and tgt and tgt:DistToSqr(tPos) < REPATH_SQR and now < (npc.NGLRepathAt or 0) then return end

	local req = (npc.NGLPathReq or 0) + 1
	npc.NGLPathReq = req
	npc.NGLRepathAt = now + 3
	local target = Vector(tPos.x, tPos.y, tPos.z)
	-- In a squad whose leader already has a path there: take it.
	local sp, sk, st = sharedPath(npc, pos, target)
	if sp then
		npc.NGLPath, npc.NGLPathIdx, npc.NGLPathTarget = sp, sk, st
		npc.NGLPathPending = false
		npc.NGLGoal = target
		nav.Stats.shared = (nav.Stats.shared or 0) + 1
		return
	end
	npc.NGLPathPending = true
	npc.NGLPathPendingSince = now
	nav.RequestPath(pos, target, function(path)
		if not IsValid(npc) or npc.NGLPathReq ~= req then return end
		npc.NGLPathPending = false
		npc.NGLGoal = target -- final leg after the last waypoint
		if path and #path > 0 then
			npc.NGLPath = path
			npc.NGLPathIdx = firstWaypoint(path, npc:GetPos())
			npc.NGLPathTarget = target
		else
			npc.NGLPath = nil
			npc.NGLPathFailUntil = CurTime() + FAIL_BACKOFF
		end
	end, function()
		return IsValid(npc) and npc.NGLPathReq == req
	end, npc.NavWidth, npc.NGLNavCaps)
	if npc.NGLPathPending and not npc.NGLPath then
		npc.NGLGoal = (not forcePath) and tPos or nil
	end
end

local INVESTIGATE_DONE_SQR = 128 * 128
local LAST_SEEN_DONE_SQR = 96 * 96

local function stopMoving(npc)
	npc.NGLPath, npc.NGLGoal = nil, nil
	npc.NGLPathPending = false
	npc.NGLPathReq = (npc.NGLPathReq or 0) + 1
end
Core.StopMoving = stopMoving
Core.Chase = chase

-- Standing around with nothing to do: now and then look somewhere else
-- (only where a player can see it; nobody notices further away).
local function lookAround(npc, now, pos)
	if not npc.NGLNear then
		npc.NGLFace = nil
		return
	end
	local L = npc.NGLLook
	if not L or now >= L.untilT or (L.from and pos:DistToSqr(L.from) > 64 * 64) then
		L = L or {}
		L.untilT, L.from, L.pos = now + Rand(3, 7), pos, nil
		if random() < 0.6 then
			local a = Rand(0, 2 * math.pi)
			L.pos = Vector(pos.x + math.cos(a) * 200, pos.y + math.sin(a) * 200, pos.z)
		end
		npc.NGLLook = L
	end
	npc.NGLFace = L.pos
end
Core.LookAround = lookAround

-- No enemy: go and look where an ally saw one, otherwise stroll around home,
-- standing a while between strolls.
local function idle(npc, now, pos)
	if npc.NGLNear and now >= (npc.NGLNextIdleSound or 0) then
		local d = npc.IdleSoundDelay
		npc.NGLNextIdleSound = now + Rand(d[1], d[2])
		npc:NGLSound("Idle")
	end
	if npc:OnIdle() == true then return end
	npc.NGLFace = nil
	npc.NGLCrouch = false

	-- Not in a group yet: team up with allies nearby (sv_squad.lua).
	local S = NGL.Squad
	if S and S.AutoGroup then S.AutoGroup(npc, now, pos) end

	-- Squad member: keep our place in the formation behind the leader.
	local sq = npc.NGLSquad
	if sq and not npc.NGLInvestigate and Core.Follow(npc, now, pos, sq) then
		if not (npc.NGLGoal or npc.NGLPath or npc.NGLPathPending) then lookAround(npc, now, pos) end
		return
	end

	local inv = npc.NGLInvestigate
	if inv then
		if now > npc.NGLInvestigateUntil or pos:DistToSqr(inv) < INVESTIGATE_DONE_SQR then
			npc.NGLInvestigate = nil
			npc.NGLHome = pos
			npc.NGLNextWander = now + Rand(1, 3)
			stopMoving(npc)
		else
			npc:NGLSetMoveMode("run")
			chase(npc, now, pos, inv, false)
			return
		end
	end

	local radius = npc.WanderRadius or 0
	if radius <= 0 then
		npc.NGLGoal, npc.NGLPath = nil, nil
		lookAround(npc, now, pos)
		return
	end
	local delay = npc.WanderDelay
	if npc.NGLPath or npc.NGLGoal or npc.NGLPathPending then -- still strolling
		npc.NGLStrolling = true
		return
	end
	if npc.NGLStrolling then
		-- Just got there: stand a while before the next stroll.
		npc.NGLStrolling = nil
		npc.NGLNextWander = now + Rand(delay[1], delay[2])
	end
	npc:NGLSetMoveMode("walk")
	npc.NGLDirect = nil
	if now < (npc.NGLNextWander or 0) then
		lookAround(npc, now, pos)
		return
	end

	npc.NGLNextWander = now + Rand(delay[1], delay[2])
	npc.NGLLook = nil
	local home = npc.NGLHome or pos
	local nav = NGL.Nav
	local path = nav and nav.Loaded and nav.RandomWalk(pos, home, radius, random(3, 8))
	if path and #path > 0 then
		npc.NGLPath = path
		npc.NGLPathIdx = 1
		npc.NGLGoal = nil
	else
		-- No grid here: a random spot; if it's inside a wall the stuck check gives up.
		local a = Rand(0, 2 * math.pi)
		local d = Rand(radius * 0.3, radius)
		npc.NGLGoal = Vector(home.x + math.cos(a) * d, home.y + math.sin(a) * d, pos.z)
	end
end

----------------------------------------------------------------------------
-- Positions: standing fights, grid spots, hiding places (used by the AI
-- modes in sv_aimodes.lua; custom modes can use them too)
----------------------------------------------------------------------------

-- A standing fight for this think: every few seconds pick crouching (hold
-- the spot), standing (hold it) or a sidestep across the line of fire.
-- stand, crouch: chances 0..1. minD/maxD: sidestep length (100..250).
-- home/leash: never step further than leash from home.
local STRAFE_TRIES = { 1, -1, 0.5, -0.5 }
local STRAFE_ROOM = 48
local strafeHull = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }
local strafeDown = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }
local function strafeOk(npc, pos, goal, home, leash)
	if home and leash and goal:DistToSqr(home) > leash * leash then return false end
	-- Someone standing there, or halfway (the spatial grid, no traces).
	local AnyNear = Core.AnyNear
	if AnyNear(goal.x, goal.y, goal.z, STRAFE_ROOM, npc)
		or AnyNear((pos.x + goal.x) * 0.5, (pos.y + goal.y) * 0.5, (pos.z + goal.z) * 0.5, STRAFE_ROOM, npc) then
		return false
	end
	-- Room to walk there (a hull trace above step height) and ground at the
	-- end (no drop): two traces, every few seconds per fighting NPC.
	local t = strafeHull
	vA:SetUnpacked(pos.x, pos.y, pos.z + 18)
	vB:SetUnpacked(goal.x, goal.y, pos.z + 18)
	t.start, t.endpos = vA, vB
	local mins, maxs = boundsOf(npc)
	vC:SetUnpacked(maxs.x, maxs.y, math.max(maxs.z - 18, 8))
	t.mins, t.maxs = mins, vC
	t.filter = npc
	local tr = util.TraceHull(t)
	if tr.Hit or tr.StartSolid then return false end
	local d = strafeDown
	vA:SetUnpacked(goal.x, goal.y, pos.z + 24)
	vB:SetUnpacked(goal.x, goal.y, pos.z - 48)
	d.start, d.endpos = vA, vB
	d.filter = npc
	tr = util.TraceLine(d)
	return tr.Hit and not tr.StartSolid
end
Core.StrafeOk = strafeOk

function Core.Strafe(npc, now, pos, tPos, stand, crouch, minD, maxD, home, leash)
	npc.NGLPath = nil
	npc.NGLDirect = nil
	npc:NGLSetMoveMode("walk")
	if now >= (npc.NGLNextStrafe or 0) then
		if not npc.NGLActs.CrouchIdle then crouch = 0 end
		local r = random()
		if r < crouch then
			npc.NGLNextStrafe = now + Rand(2.5, 5)
			npc.NGLCrouch = true
			npc.NGLGoal = nil
		elseif r < crouch + stand then
			npc.NGLNextStrafe = now + Rand(1.5, 3.5)
			npc.NGLCrouch = false
			npc.NGLGoal = nil
		else
			npc.NGLNextStrafe = now + Rand(2, 3.5)
			npc.NGLCrouch = false
			local dir = tPos - pos
			dir.z = 0
			dir:Normalize()
			local side = (random(2) == 1) and 1 or -1
			local step = Vector(-dir.y, dir.x, 0) * Rand(minD or 100, maxD or 250)
			-- One side, else the other, else half as far: somewhere inside the
			-- leash, on the grid with nothing in the way, and not into someone.
			local goal
			for _, f in ipairs(STRAFE_TRIES) do
				local g = pos + step * (side * f)
				if strafeOk(npc, pos, g, home, leash) then goal = g break end
			end
			npc.NGLGoal = goal
		end
	end
	npc.NGLFace = tPos
end

-- Where an entity looks from, and which way it faces.
function Core.EyeOf(ent)
	if ent:IsPlayer() then return ent:EyePos() end
	if ent.IsNGLNPC then
		local p = ent:GetPos()
		p.z = p.z + eyeHeight(ent)
		return p
	end
	return ent:WorldSpaceCenter()
end

function Core.FacingYaw(ent)
	if ent:IsPlayer() then return ent:EyeAngles().y end
	return ent:GetAngles().y
end

-- The nav grid point nearest to `pos` (looking down for the ground first
-- when `pos` is up in the air or on a slope), or `pos` itself without a grid.
local groundTrace = { mask = MASK_SOLID_BRUSHONLY }
local groundResult = {}
groundTrace.output = groundResult
function Core.GridSpot(pos)
	local nav = NGL.Nav
	if not (nav and nav.Loaded) then return pos end
	local n = nav.Nearest(pos)
	if not n then
		groundTrace.start = Vector(pos.x, pos.y, pos.z + 256)
		groundTrace.endpos = Vector(pos.x, pos.y, pos.z - 512)
		util.TraceLine(groundTrace)
		if groundResult.Hit then n = nav.Nearest(groundResult.HitPos) end
	end
	return n and nav.NodePos(n) or nil, n
end

-- Is a man standing at `spot` out of sight from `eye`? (head and feet)
local hideTrace = { mask = MASK_SOLID_BRUSHONLY }
local hideResult = {}
hideTrace.output = hideResult
function Core.HiddenFrom(eye, spot)
	hideTrace.start = eye
	hideTrace.endpos = Vector(spot.x, spot.y, spot.z + 64)
	util.TraceLine(hideTrace)
	if not hideResult.Hit then return false end
	hideTrace.endpos = Vector(spot.x, spot.y, spot.z + 16)
	util.TraceLine(hideTrace)
	return hideResult.Hit == true
end

-- A grid spot minR..maxR from `center` that `eye` can't see, nearest to
-- the NPC, or nil. `yaws`: directions to try (degrees); by default 8 all
-- round. `notNear`: skip spots within 300 units of this position (e.g.
-- where the NPC already is). Two traces per direction at most, so call it
-- now and then, not every think.
local ALL_ROUND = { 0, 45, 90, 135, 180, 225, 270, 315 }
function Core.FindHiddenSpot(npc, eye, center, minR, maxR, yaws, notNear)
	local pos = npc:GetPos()
	local best, bestD
	local spin = yaws and 0 or Rand(0, 45)
	for _, a in ipairs(yaws or ALL_ROUND) do
		local r = math.rad(a + spin)
		local d = Rand(minR, maxR)
		local spot = Core.GridSpot(Vector(center.x + math.cos(r) * d, center.y + math.sin(r) * d, center.z))
		if spot and not (notNear and spot:DistToSqr(notNear) < 300 * 300) and Core.HiddenFrom(eye, spot) then
			local dd = pos:DistToSqr(spot)
			if not bestD or dd < bestD then best, bestD = spot, dd end
		end
	end
	return best
end

----------------------------------------------------------------------------
-- Squads and orders (squads themselves: sv_squad.lua)
----------------------------------------------------------------------------

-- Formations, relative to the leader: (slot, row, side) -> back, sideways.
--   wedge:  a V behind the leader, two members per row
--   line:   side by side with the leader, a step behind
--   column: one behind the other, slightly staggered
local SLOT_BACK, SLOT_SIDE = 90, 80
local FOLLOW_OK_SQR = 120 * 120   -- close enough to our slot: stand
local FOLLOW_RUN_SQR = 500 * 500  -- this far behind: run to catch up

local FORMATIONS = {
	-- loose: no set places (Core.Follow below): the group of ordinary NPCs
	-- that teamed up on their own. This is only its fallback shape.
	loose = function(slot, row, side) return SLOT_BACK * row * 1.5, SLOT_SIDE * row * side * 1.5 end,
	wedge = function(slot, row, side) return SLOT_BACK * row, SLOT_SIDE * row * side end,
	line = function(slot, row, side) return 40, SLOT_SIDE * row * side end,
	column = function(slot, row, side) return SLOT_BACK * 0.8 * slot, 24 * side end,
}
Core.Formations = FORMATIONS

function Core.SlotPos(leader, slot, formation)
	local row = math.ceil(slot / 2)
	local side = (slot % 2 == 1) and 1 or -1
	local yaw = math.rad(leader:GetAngles().y)
	local fx, fy = math.cos(yaw), math.sin(yaw)
	local back, lat = (FORMATIONS[formation] or FORMATIONS.wedge)(slot, row, side)
	back = -back
	local lp = leader:GetPos()
	return Vector(lp.x + fx * back - fy * lat, lp.y + fy * back + fx * lat, lp.z)
end

-- Loose group: each member picks its own spot somewhere round the leader
-- and stays there, looking about, until the leader has moved off; then it
-- strolls after it to a new spot. No set places, no turning with the leader.
local LOOSE_MIN, LOOSE_MAX = 90, 240
local LOOSE_LEAVE_SQR = 380 * 380 -- leader this far from where we settled: follow
local LOOSE_OK_SQR = 60 * 60

local function followLoose(npc, now, pos, sq, leader)
	local lp = leader:GetPos()
	local L = npc.NGLLoose
	if not L or L.sq ~= sq or lp:DistToSqr(L.anchor) > LOOSE_LEAVE_SQR then
		-- Not straight away when the leader sets off: people don't move as one.
		if L and L.sq == sq and not L.waitT then L.waitT = now + Rand(0.3, 2) end
		if L and L.waitT and now < L.waitT then return true end
		local goal, raw
		for _ = 1, 3 do
			local a, d = Rand(0, 2 * math.pi), Rand(LOOSE_MIN, LOOSE_MAX)
			raw = Vector(lp.x + math.cos(a) * d, lp.y + math.sin(a) * d, lp.z)
			goal = Core.GridSpot(raw)
			if goal then break end
		end
		L = { sq = sq, anchor = lp, goal = goal or raw } -- off the grid: walk there straight
		npc.NGLLoose = L
	end
	local dSqr = pos:DistToSqr(L.goal)
	if dSqr < LOOSE_OK_SQR then
		if npc.NGLGoal or npc.NGLPath or npc.NGLPathPending then stopMoving(npc) end
		return true
	end
	npc:NGLSetMoveMode(dSqr > 700 * 700 and "run" or "walk")
	chase(npc, now, pos, L.goal, dSqr < 400 * 400)
	return true
end

-- Returns true when it moved the NPC (or kept it in place) as a follower.
function Core.Follow(npc, now, pos, sq)
	local leader = sq.leader
	local slot = sq.slots[npc]
	if not (slot and IsValid(leader) and leader ~= npc) or leader.NGLDying then return false end
	if sq.formation == "loose" then return followLoose(npc, now, pos, sq, leader) end
	local goal = Core.SlotPos(leader, slot, sq.formation)
	local dSqr = pos:DistToSqr(goal)
	if dSqr < FOLLOW_OK_SQR then
		if npc.NGLGoal or npc.NGLPath or npc.NGLPathPending then stopMoving(npc) end
		return true
	end
	npc:NGLSetMoveMode(dSqr > FOLLOW_RUN_SQR and "run" or "walk")
	-- Short hops straight; longer ones along the grid.
	chase(npc, now, pos, goal, dSqr < 400 * 400)
	return true
end

-- Default lengths in seconds, when an order has no `time`.
local ORDER_TIME = { hold = 10, move = 30, search = 20, fire_at = 4 }
Core.OrderTime = ORDER_TIME
local ARRIVE_SQR = 64 * 64

-- Gives an order (see ENT:GiveOrder for the fields). Returns true if taken.
function Core.GiveOrder(npc, order, now)
	local base = ORDER_TIME[order.kind]
	if not base and not (npc.OrderKinds and npc.OrderKinds[order.kind]) then return false end
	-- Sent somewhere by a player (NGL NPC Mover): squad orders wait till it's there.
	local cur = npc.NGLOrder
	if cur and cur.byPlayer and not order.byPlayer and now < cur.untilT then return false end
	if npc:OnOrder(order) == true then return true end -- handled by the NPC itself
	if npc.NGLOrder then Core.EndOrder(npc, "replaced") end
	order.untilT = now + (order.time or base or 10)
	order.startT = now
	npc.NGLOrder = order
	npc.NGLFireAccum = 0
	stopMoving(npc)
	Core.Wake(npc)
	return true
end

function Core.EndOrder(npc, reason)
	local o = npc.NGLOrder
	if not o then return end
	npc.NGLOrder = nil
	npc.NGLCrouch = false
	if o.kind ~= "hold" then stopMoving(npc) end
	npc:OnOrderDone(o, reason)
	if o.onDone then o.onDone(npc, o, reason) end
end

-- Fight back from where we stand if the enemy is in view: a swing when it's
-- in reach, shots when it's in range.
local function returnFire(npc, now, dt, pos, enemy, visible)
	if not (enemy and visible) then return false end
	local tPos = enemy:GetPos()
	local m = npc.Melee
	if m then
		local reach = m.Range or 70
		if pos:DistToSqr(tPos) < reach * reach and abs(tPos.z - pos.z) < 72 then
			npc.NGLFace = tPos
			if now >= (npc.NGLNextMelee or 0) and npc:OnAttack(enemy, "melee") ~= true then
				Core.StartMelee(npc, enemy, now)
			end
			return true
		end
	end
	if not npc.Weapon then return false end
	local range = npc.AttackRange * 1.2
	if pos:DistToSqr(tPos) > range * range then return false end
	npc.NGLFace = tPos
	shoot(npc, now, dt, enemy)
	return true
end

-- Runs one think of the NPC's order. Returns true when the order handled
-- the think, false to let the normal behaviour run (order over or broken off).
function Core.RunOrder(npc, now, dt, pos, o, enemy, visible)
	if now >= o.untilT then
		Core.EndOrder(npc, "timeout")
		return false
	end
	local kind = o.kind

	if kind == "hold" then
		-- Stay put (crouched if we can), watch `face`, shoot what we see.
		if npc.NGLGoal or npc.NGLPath or npc.NGLPathPending then stopMoving(npc) end
		npc:NGLSetMoveMode("walk")
		npc.NGLCrouch = o.crouch ~= false and npc.NGLActs.CrouchIdle ~= nil
		if not returnFire(npc, now, dt, pos, enemy, visible) then
			npc.NGLFace = o.face
			npc.NGLFireAccum = 0
		end
		return true

	elseif kind == "move" then
		-- Go to `pos` (running if `run`), shooting what we see on the way;
		-- then hold there if `hold`, else the order is done.
		if pos:DistToSqr(o.pos) < (o.radius and o.radius * o.radius or ARRIVE_SQR) then
			if o.hold then
				o.kind = "hold"
				o.untilT = now + (o.holdTime or ORDER_TIME.hold)
				stopMoving(npc)
				return true
			end
			Core.EndOrder(npc, "done")
			return false
		end
		npc.NGLCrouch = false
		npc:NGLSetMoveMode(o.run and "run" or "walk")
		chase(npc, now, pos, o.pos, pos:DistToSqr(o.pos) < 300 * 300)
		if not returnFire(npc, now, dt, pos, enemy, visible) then
			npc.NGLFace = nil
			npc.NGLFireAccum = 0
		end
		return true

	elseif kind == "search" then
		-- Walk to `pos`, then sweep around it (`radius`, default 400) until the
		-- time runs out. Seeing an enemy ends the order and we fight.
		if enemy and visible then
			Core.EndOrder(npc, "contact")
			return false
		end
		npc.NGLCrouch = false
		npc.NGLFace = nil
		local radius = o.radius or 400
		if not o.sweeping then
			if pos:DistToSqr(o.pos) < (radius * 0.75) ^ 2 then
				o.sweeping = true
				stopMoving(npc)
			else
				npc:NGLSetMoveMode(o.run == false and "walk" or "run")
				chase(npc, now, pos, o.pos, false)
				return true
			end
		end
		npc:NGLSetMoveMode("walk")
		if not (npc.NGLPath or npc.NGLGoal or npc.NGLPathPending) then
			local nav = NGL.Nav
			local path = nav and nav.Loaded and nav.RandomWalk(pos, o.pos, radius, random(3, 6))
			if path and #path > 0 then
				npc.NGLPath, npc.NGLPathIdx = path, 1
			else
				local a = Rand(0, 2 * math.pi)
				local d = Rand(radius * 0.3, radius)
				npc.NGLGoal = Vector(o.pos.x + math.cos(a) * d, o.pos.y + math.sin(a) * d, pos.z)
			end
		end
		return true

	elseif kind == "fire_at" then
		-- Stand and shoot at the area around `pos`, seen or not.
		if npc.NGLGoal or npc.NGLPath or npc.NGLPathPending then stopMoving(npc) end
		local p = o.pos
		npc.NGLFace = p
		local sp = o.spread or 150
		local dst = Vector(p.x + Rand(-sp, sp), p.y + Rand(-sp, sp), p.z + 32)
		shoot(npc, now, dt, nil, dst)
		return true
	end

	-- A kind only the NPC knows: it runs it in OnAIThink; nothing to do here.
	return false
end

-- One AI decision for one NPC. `dt` is the time since its last think.
-- Players and NPCs, as in HL2: NPCs are solid to players and never end up
-- inside one. Melee NPCs stop a body's width short (see the fight), shoves
-- don't move them into a player (slideTo), and one that ends up inside a
-- player anyway (a headcrab landing on you) steps straight back out of
-- them, nothing else changes.
local PLAYER_R = 16
local function playerOverlap(npc, now)
	if npc.IsVehicleNPC or npc.NGLTraverse or npc.NGLLeapState then return end
	local pos = npc:GetPos()
	local myR = radiusOf(npc)
	local h = npc.Hull and npc.Hull[2].z or 72
	local touch = myR + PLAYER_R
	for i = 1, #players do
		local ply = players[i]
		local pp = ply:GetPos()
		local dz = pp.z - pos.z
		local ph = ply:Crouching() and 36 or 72
		-- Standing on a player's head (a headcrab after its bite): off it,
		-- or it rides there out of reach of your gun.
		if dz <= -ph + 4 and dz > -ph - 12 then dz = 0 end
		if dz < h and dz > -ph then
			local ox, oy = pos.x - pp.x, pos.y - pp.y
			local d2 = ox * ox + oy * oy
			if d2 < touch * touch then
				local d = math.sqrt(d2)
				local bx, by
				if d >= 1 then bx, by = ox / d, oy / d else bx, by = apartDir(npc, pos, ply, pp) end
				npc.NGLShoveIgnore = ply
				shove(npc, bx, by, 160, now)
				return
			end
		end
	end
end

-- On rails (ngl_ai_rail_range): far from every player and out of sight,
-- an NPC on a nav path doesn't walk with the NextBot locomotion every tick
-- (ground and hull traces each tick, every NPC). At each think it is moved
-- straight along its path by as far as it would have walked since the last
-- one, put on the ground with one trace, and faces the way it goes;
-- BehaveUpdate leaves it alone in between. Jumps and climbs on the path are
-- simply passed. As soon as a player comes near or can see it, it walks
-- normally again from where it is on the same path.
local railDown = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }
local RAIL_MAX_DT = 2
local function railOk(npc, nearestPlayerSqr, seen)
	if seen or not npc.NGLPath then return false end
	local r = cvRail:GetFloat()
	if r <= 0 or nearestPlayerSqr < r * r then return false end
	return not (npc.NGLTraverse or npc.NGLLeapState or npc.IsVehicleNPC or npc.NGLDrive
		or npc.NGLAnimUntil or npc.NGLMeleeHitAt or npc.Flying or npc.NGLFly)
end

local function railStep(npc, pos, dt)
	local path = npc.NGLPath
	local idx = npc.NGLPathIdx or 1
	local left = npc.loco:GetDesiredSpeed() * min(dt, RAIL_MAX_DT)
	local x, y, z = pos.x, pos.y, pos.z
	local fx, fy
	while left > 0 do
		local wp = path[idx]
		if not wp then break end
		local dx, dy, dz = wp.x - x, wp.y - y, wp.z - z
		local d = math.sqrt(dx * dx + dy * dy)
		if d > 1 then fx, fy = dx, dy end
		if d <= left then
			x, y, z = wp.x, wp.y, wp.z
			left = left - d
			idx = idx + 1
		else
			local f = left / d
			x, y, z = x + dx * f, y + dy * f, z + dz * f
			left = 0
		end
	end
	npc.NGLPathIdx = idx
	if not path[idx] then npc.NGLPath = nil end
	-- A straight line between two path points can cut into a hill: the
	-- ground under the new spot, from a little above.
	local t = railDown
	vA:SetUnpacked(x, y, z + 48)
	vB:SetUnpacked(x, y, z - 96)
	t.start, t.endpos = vA, vB
	t.filter = npc
	local tr = util.TraceLine(t)
	if tr.Hit and not tr.StartSolid then z = tr.HitPos.z end
	local to = Vector(x, y, z + 2)
	npc:SetPos(to)
	if fx then npc:SetAngles(Angle(0, math.deg(math.atan2(fy, fx)), 0)) end
	npc.NGLMoving = true
	npc.NGLSteer = npc.NGLPath and npc.NGLPath[idx] or nil
	local A = npc.NGLActs
	if A then npc:NGLSetAct(npc.NGLMoveMode == "walk" and A.Walk or A.Run) end
	gridUpdate(npc, to)
	npc.NGLGridPos = to
	if not npc.NGLPath then npc.NGLRail = nil end
	return to
end

----------------------------------------------------------------------------
-- Melee attack slots
----------------------------------------------------------------------------

-- Like HL2's squad slots: only a few melee NPCs at a time close in on one
-- target (ngl_ai_melee_slots, more round a big one). The others wait in a
-- loose ring a little further out, facing it, and take a free slot as soon
-- as one comes up, or go for another target nearby that has room. Without
-- this a horde of 100 zombies on one rebel ended up as one heap: every one
-- of them pushing and pushed, swinging and making noise, and a heap looks
-- wrong. A slot lasts while it's renewed (each think of its holder) and is
-- dropped when the holder dies, changes target or moves off.
local cvSlots = CreateConVar("ngl_ai_melee_slots", "5", FCVAR_ARCHIVE,
	"How many NGL melee NPCs (zombies, headcrabs) close in on one target at a time; the rest wait round it a little further out. More round big targets. 0 = no limit.", 0, 64)
local SLOT_HOLD = 2       -- s a slot lasts without being renewed
local SLOT_ASK = 150      -- asks for a slot this far outside the waiting ring
local WAIT_RING = 170     -- waiting distance from the target's edge, first band
local WAIT_BAND = 60      -- each further band (three bands)
local WAIT_OK_SQR = 40 * 40
local OTHER_EVERY = 1     -- s between looks for another target with room
local OTHER_RANGE = 700
local KEEP_OTHER = 4      -- s it stays on a target it picked for its room

local function slotMax(target)
	local n = target.MeleeSlots
	if n then return n end
	n = cvSlots:GetInt()
	if n <= 0 then return 0 end
	-- Bigger than a man (a vehicle, an antlion guard): room for more.
	local r = target:IsPlayer() and PLAYER_R or radiusOf(target)
	return math.Round(n * math.Clamp(r / 16, 1, 4))
end

-- Holders of `target`'s slots, the stale ones cleared out on the way.
local function slotCount(target, now)
	local S = target.NGLMeleeSlots
	if not S then return 0, nil end
	local n = 0
	for e, untilT in pairs(S) do
		if untilT < now or not IsValid(e) or e.NGLDying or e.NGLEnemy ~= target then
			S[e] = nil
		else
			n = n + 1
		end
	end
	return n, S
end

local function releaseSlot(npc)
	local t = npc.NGLSlotTarget
	if not t then return end
	npc.NGLSlotTarget = nil
	local S = IsValid(t) and t.NGLMeleeSlots
	if S then S[npc] = nil end
end
Core.ReleaseSlot = releaseSlot

-- May `npc` close in on `target` now? Takes (or renews) a slot when so.
function Core.MeleeSlot(npc, target, now)
	local cap = slotMax(target)
	if cap <= 0 then return true end
	local S = target.NGLMeleeSlots
	if S and S[npc] and npc.NGLSlotTarget == target then
		S[npc] = now + SLOT_HOLD
		return true
	end
	local n
	n, S = slotCount(target, now)
	if n >= cap then return false end
	if npc.NGLSlotTarget ~= target then releaseSlot(npc) end
	if not S then
		S = {}
		target.NGLMeleeSlots = S
	end
	S[npc] = now + SLOT_HOLD
	npc.NGLSlotTarget = target
	return true
end

function Core.SlotFree(target, now)
	local cap = slotMax(target)
	return cap <= 0 or slotCount(target, now) < cap
end

-- Another hostile within OTHER_RANGE with a free slot, nearest first, and
-- in sight (one trace, for the nearest only). Players, then the grid.
local function otherTarget(npc, pos, now, current)
	local best, bestD
	local rSqr = OTHER_RANGE * OTHER_RANGE
	for i = 1, #players do
		local ply = players[i]
		if ply ~= current and Core.IsHostile(npc, ply) then
			local d = pos:DistToSqr(plyPos[i])
			if d < rSqr and (not bestD or d < bestD) and Core.SlotFree(ply, now) then best, bestD = ply, d end
		end
	end
	local r = math.ceil(OTHER_RANGE / CELL)
	local cx, cy = floor(pos.x / CELL) + OFFSET, floor(pos.y / CELL) + OFFSET
	local faction = npc.Faction
	for gx = cx - r, cx + r do
		local base = gx * 4096
		for gy = cy - r, cy + r do
			local c = cells[base + gy]
			if c then
				for e in pairs(c) do
					local p = e.NGLGridPos
					if p and e ~= current and e ~= npc and e.Faction ~= faction and Core.IsHostile(npc, e) then
						local d = pos:DistToSqr(p)
						if d < rSqr and (not bestD or d < bestD) and Core.SlotFree(e, now) then best, bestD = e, d end
					end
				end
			end
		end
	end
	if not best then return nil end
	eyeVec:SetUnpacked(pos.x, pos.y, pos.z + npc.EyeHeight)
	if not canSee(npc, eyeVec, best) then return nil end
	return best
end

-- No slot: wait on the ring round the target, on our side of it, facing
-- it. Each NPC has its band (from its entity number), so waiters stand in
-- three loose rows rather than one tight circle, and moves a little now
-- and then. Straight there: the target is in sight and the spot near it.
local function meleeWait(npc, now, pos, enemy, tPos)
	if now >= (npc.NGLNextOther or 0) then
		npc.NGLNextOther = now + OTHER_EVERY * Rand(0.8, 1.2)
		local other = otherTarget(npc, pos, now, enemy)
		if other then
			Core.SetEnemy(npc, other)
			npc.NGLKeepEnemyUntil = now + KEEP_OTHER
			return
		end
	end
	local W = npc.NGLWait
	if not W or W.target ~= enemy or now >= W.untilT or (tPos.x - W.ax) ^ 2 + (tPos.y - W.ay) ^ 2 > 80 * 80 then
		W = W or {}
		local gap = enemy:IsPlayer() and PLAYER_R or radiusOf(enemy)
		local r = gap + radiusOf(npc) + WAIT_RING + (idOf(npc) % 3) * WAIT_BAND
		local a = math.atan2(pos.y - tPos.y, pos.x - tPos.x) + Rand(-0.3, 0.3)
		W.target, W.untilT, W.ax, W.ay = enemy, now + Rand(2, 4), tPos.x, tPos.y
		W.x, W.y, W.z = tPos.x + math.cos(a) * r, tPos.y + math.sin(a) * r, pos.z
		npc.NGLWait = W
	end
	npc.NGLWaiting = now
	npc.NGLFace = tPos
	npc.NGLCrouch = false
	npc.NGLPath = nil
	local dx, dy = W.x - pos.x, W.y - pos.y
	local d2 = dx * dx + dy * dy
	if d2 < WAIT_OK_SQR then
		npc.NGLGoal = nil
		return
	end
	local v = npc.NGLWaitVec
	if not v then
		v = Vector()
		npc.NGLWaitVec = v
	end
	v:SetUnpacked(W.x, W.y, W.z)
	npc:NGLSetMoveMode(d2 > 150 * 150 and "run" or "walk")
	npc.NGLGoal = v
	npc.NGLDirect = true
end

-- Pushing, standing inside each other, and shortcuts on the path.
local function crowdCheck(npc, now, pos)
	pushCheck(npc, now, pos)
	overlapCheck(npc, now, pos)
	if npc.NGLPath then Core.Shortcut(npc, now, pos) end
end

local function think(npc, now, dt, nearestPlayerSqr, seen, pos)
	npc.NGLNear = nearestPlayerSqr < cvVisual:GetFloat() ^ 2 -- sounds and voice lines: by distance
	npc.NGLSeen = seen -- some player may see it (in range and in their PVS)
	local detailSqr = cvDetail:GetFloat() ^ 2
	npc.NGLDetail = seen and nearestPlayerSqr < (npc.NGLDetail and detailSqr * DETAIL_LEAVE or detailSqr)
	if npc.NGLMeleeHitAt and now >= npc.NGLMeleeHitAt then resolveMelee(npc) end
	if nearestPlayerSqr < 10000 then playerOverlap(npc, now) end
	if npc:OnAIThink(dt) == true then return end
	pos = pos or npc:GetPos()
	if now < (npc.NGLBusyUntil or 0) then -- mid-swing or playing a locked animation
		gridUpdate(npc, pos)
		return
	end

	gridUpdate(npc, pos)
	npc.NGLGridPos = pos
	if not npc.NGLPlaced then
		npc.NGLPlaced = true
		Core.PlaceFree(npc, pos)
		pos = npc:GetPos()
		gridUpdate(npc, pos)
		npc.NGLGridPos = pos
	end
	if railOk(npc, nearestPlayerSqr, seen) then
		npc.NGLRail = true
		pos = railStep(npc, pos, dt)
	elseif npc.NGLRail then
		npc.NGLRail = nil
	end
	if not npc.NGLTraverse then
		if not npc.NGLRail then
			local AL = NGL.Alloc
			if AL and AL.On() then
				AL.Measure("think: crowd checks and shortcuts", crowdCheck, npc, now, pos)
			else
				crowdCheck(npc, now, pos)
			end
		end
		-- A closed door in the way: open it or kick it in (sv_doors.lua).
		local D = NGL.Doors
		if D and npc.NGLMoving and (npc.OpenDoors or npc.DoorBreach) then D.Think(npc, now, pos) end
	end

	-- Squad leaders (ENT.Squad): recruiting and commanding, twice a second.
	if npc.Squad then NGL.Squad.LeaderThink(npc, now, pos) end

	-- Stuck (not moved 16 units in 2 s while trying to): drop the path and
	-- strafe goal so the next decision starts fresh.
	if npc.NGLGoal or npc.NGLPath then
		local sp = npc.NGLStuckPos
		if not sp or pos:DistToSqr(sp) >= STUCK_SQR then
			npc.NGLStuckPos, npc.NGLStuckT, npc.NGLSlid = pos, now, nil
		elseif now - npc.NGLStuckT > SLIDE_AFTER and not npc.NGLSlid then
			-- Caught on a door frame or a wall's corner: slide along it.
			npc.NGLSlid = true
			Core.SlideAlongWall(npc, now, pos)
		elseif now - npc.NGLStuckT > 2.5 then
			-- Walking straight into something: use the grid for a while.
			if npc.NGLDirect then npc.NGLForcePathUntil = now + FORCE_PATH end
			stopMoving(npc)
			npc.NGLStuckPos = nil
			npc.NGLPathFailUntil = 0
			npc.NGLRepathAt, npc.NGLNextStrafe = 0, 0
		end
	else
		npc.NGLStuckPos = nil
	end

	local enemy = npc.NGLEnemy
	local enemyOk = IsValid(enemy) and enemy:Health() > 0 and Core.IsHostile(npc, enemy)

	if not enemyOk or now >= npc.NGLNextRetarget then
		npc.NGLNextRetarget = now + Rand(0.8, 1.2)
		local AL = NGL.Alloc
		local found
		if AL and AL.On() then
			found = AL.Measure("think: enemy search", findEnemy, npc, pos)
		else
			found = findEnemy(npc, pos)
		end
		if found and found ~= enemy and enemyOk and now < (npc.NGLKeepEnemyUntil or 0) then
			-- On a target it went for because it had room (melee slots):
			-- stays on it a while, rather than back to the crowded one.
		elseif found then
			Core.SetEnemy(npc, found)
			npc.NGLLastSeenPos, npc.NGLLastSeenT = found:GetPos(), now
		elseif not enemyOk or now - (npc.NGLLastSeenT or 0) > npc.EnemyMemory then
			-- Dead, gone, or out of sight for too long.
			Core.SetEnemy(npc, nil)
		end
		enemy = npc.NGLEnemy
		enemyOk = IsValid(enemy)
	end

	-- Line of sight to the current enemy, rechecked at most twice a second.
	local tPos = enemyOk and enemy:GetPos()
	if enemyOk and now >= (npc.NGLNextVis or 0) then
		npc.NGLNextVis = now + 0.5
		eyeVec:SetUnpacked(pos.x, pos.y, pos.z + eyeHeight(npc))
		npc.NGLEnemyVisible = canSee(npc, eyeVec, enemy)
		if npc.NGLEnemyVisible then npc.NGLLastSeenPos, npc.NGLLastSeenT = tPos, now end
	end
	local visible = enemyOk and npc.NGLEnemyVisible

	-- An order (squad leader, script) comes before the NPC's own plans.
	local order = npc.NGLOrder
	if order and Core.RunOrder(npc, now, dt, pos, order, enemyOk and enemy or nil, visible) then return end

	if not enemyOk then
		idle(npc, now, pos)
		return
	end
	local distSqr = pos:DistToSqr(tPos)
	local dist = math.sqrt(distSqr)
	if npc:OnCombat(enemy, dist, visible) == true then return end

	-- The NPC's AI mode (sv_aimodes.lua) fights its own way; a mode without
	-- a Fight, or one that returns nothing, gets the default below.
	local mode = npc.NGLMode
	local fight = mode and mode.Fight

	-- Out of sight: hunt it down where we last saw it (no seeing through walls).
	if not visible then
		if fight and fight(npc, enemy, dist, false, now, dt) == true then return end
		local last = npc.NGLLastSeenPos or tPos
		if pos:DistToSqr(last) < LAST_SEEN_DONE_SQR then
			Core.SetEnemy(npc, nil) -- it's not here; look around from here
			idle(npc, now, pos)
			return
		end
		npc:NGLSetMoveMode("run")
		npc.NGLCrouch = false
		chase(npc, now, pos, last, false)
		npc.NGLNextStrafe = 0
		npc.NGLFireAccum = 0
		npc.NGLFace = nil -- look where we walk
		return
	end

	-- Melee: in reach -> swing (also for NPCs that have a gun).
	local m = npc.Melee
	local reach = m and (m.Range or 70)
	if m and distSqr < reach * reach and abs(tPos.z - pos.z) < 72 and now >= (npc.NGLNextMelee or 0)
		and not (NGL.Off.melee and NGL.IsOff(npc, "melee")) then
		if npc:OnAttack(enemy, "melee") ~= true then Core.StartMelee(npc, enemy, now) end
		return
	end

	local w = npc.Weapon
	if not w then
		-- No gun: the AI mode first (the ambusher hides and waits), then a
		-- leap when it has one (ENT.LeapAttack, sv_leap.lua).
		if fight and fight(npc, enemy, dist, true, now, dt) == true then return end
		-- Close to it: only with a slot (leaping at it is closing in too).
		local gap = radiusOf(npc) + (enemy:IsPlayer() and PLAYER_R or radiusOf(enemy))
		local ask = gap + WAIT_RING + 2 * WAIT_BAND + SLOT_ASK
		if distSqr < ask * ask then
			if not Core.MeleeSlot(npc, enemy, now) then
				meleeWait(npc, now, pos, enemy, tPos)
				return
			end
		elseif npc.NGLSlotTarget then
			releaseSlot(npc)
		end
		local lp = npc.LeapAttack
		if lp and NGL.Leap and not (NGL.Off.leap and NGL.IsOff(npc, "leap")) and NGL.Leap.Can(npc, enemy, dist, now, lp) then
			if npc:OnAttack(enemy, "leap") ~= true then NGL.Leap.Start(npc, enemy, lp, now) end
			return
		end
		-- Melee only: close in (straight, since we can see it) and wait for the next swing.
		npc:NGLSetMoveMode("run")
		npc.NGLFace = tPos
		npc.NGLDirect = true
		if m and distSqr < (reach * 0.8) ^ 2 then
			npc.NGLPath, npc.NGLGoal = nil, nil
		else
			chase(npc, now, pos, tPos, true)
			-- Walking straight at it: stop a body's width short, not in it
			-- (between thinks the NPC keeps walking to where it aimed).
			local g = npc.NGLGoal
			if npc.NGLDirect and g == tPos then
				local stop = gap + 4
				local ddx, ddy = tPos.x - pos.x, tPos.y - pos.y
				local dl = math.sqrt(ddx * ddx + ddy * ddy)
				if dl > stop then
					-- A vector of its own, refilled each think.
					local v = npc.NGLCloseVec
					if not v then
						v = Vector()
						npc.NGLCloseVec = v
					end
					v:SetUnpacked(tPos.x - ddx / dl * stop, tPos.y - ddy / dl * stop, tPos.z)
					npc.NGLGoal = v
				else
					npc.NGLGoal = nil
				end
			end
		end
		return
	end

	if fight and fight(npc, enemy, dist, true, now, dt) == true then return end

	local range = npc.AttackRange
	if distSqr > range * range * ATTACK_KEEP_SQR_PAD then
		npc:NGLSetMoveMode("run")
		npc.NGLCrouch = false
		chase(npc, now, pos, tPos, true)
		npc.NGLNextStrafe = 0
		npc.NGLFireAccum = 0
		npc.NGLFace = tPos
		return
	end

	-- In range and in view: stand, crouch or sidestep, and shoot.
	local stand = mode and mode.StandChance or npc.StandChance or 0
	local crouch = mode and mode.CrouchChance or npc.CrouchChance or 0
	Core.Strafe(npc, now, pos, tPos, stand, crouch)
	shoot(npc, now, dt, enemy)
end

----------------------------------------------------------------------------
-- Scheduler
----------------------------------------------------------------------------

-- Could any player see it? Within ngl_ai_visual_range of one, and inside
-- that player's PVS (the engine's own "potentially visible" test: a wall
-- between hides it, an open doorway doesn't). The PVS is generous, so an
-- NPC a player can see always counts as seen.
local function seenByPlayer(npc, pos, best, visualSqr, np, pvs)
	if best >= visualSqr then return false end
	if not pvs then return true end
	for p = 1, np do
		if pos:DistToSqr(plyPos[p]) < visualSqr and players[p]:TestPVS(npc) then return true end
	end
	return false
end

-- Nothing to do: no enemy, order, alert or move, not mid-attack, not a
-- vehicle (vehicles patrol and report to their commander).
local function isIdle(npc)
	return npc.NGLEnemy == nil and not npc.NGLOrder and not npc.NGLInvestigate
		and not npc.NGLPath and not npc.NGLGoal and not npc.NGLMeleeHitAt
		and not npc.NGLLeapState and not npc.NGLTraverse and not npc.IsVehicleNPC
end

hook.Add("Tick", "NGL.Core.Scheduler", function()
	local n = #List
	if n == 0 then return end
	if aiDisabled and aiDisabled:GetBool() then return end

	local start = SysTime()
	local budget = cvBudget:GetFloat() / 1000
	local now = CurTime()

	-- Player positions once per tick (there are few players, many NPCs).
	local np = 0
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() then
			np = np + 1
			players[np] = ply
			plyPos[np] = ply:GetPos()
		end
	end
	for i = np + 1, #players do players[i] = nil end
	for i = np + 1, #plyPos do plyPos[i] = nil end

	local nearSqr, midSqr = cvNear:GetFloat() ^ 2, cvMid:GetFloat() ^ 2
	local rNear, rMid, rFar = cvRateNear:GetFloat(), cvRateMid:GetFloat(), cvRateFar:GetFloat()
	local rSleep = cvRateSleep:GetFloat()
	local visualSqr = cvVisual:GetFloat() ^ 2
	local pvs = cvPVS:GetBool()
	local lagR = cvLagRange:GetFloat()
	local lagSqr = lagR > 0 and lagR * lagR or math.huge
	local B = NGL.Bench

	for i = 1, n do
		local idx = ((cursor + i - 1) % n) + 1
		local npc = List[idx]
		if npc and now >= npc.NGLNextThink then
			if not IsValid(npc) then
				Core.Remove(npc)
			else
				local pos = npc:GetPos()
				local best = math.huge
				for p = 1, np do
					local d = pos:DistToSqr(plyPos[p])
					if d < best then best = d end
				end
				local seen = seenByPlayer(npc, pos, best, visualSqr, np, pvs)

				-- Near but out of every player's sight: the medium rate.
				-- Far, with nothing to do: asleep (Core.Wake ends it early).
				local interval
				if best < nearSqr then
					interval = seen and rNear or rMid
				elseif best < midSqr then
					interval = rMid
				elseif rSleep > rFar and isIdle(npc) then
					interval = rSleep
				else
					interval = rFar
				end
				local dt = now - npc.NGLLastThink
				if B then
					B.ThinkLate = (B.ThinkLate or 0) + (now - npc.NGLNextThink)
					B.ThinkN = (B.ThinkN or 0) + 1
				end
				npc.NGLLastThink = now
				npc.NGLNextThink = now + interval * Rand(0.9, 1.1)

				local AL = NGL.Alloc
				if NGL.Off.think and NGL.IsOff(npc, "think") then
					-- ngl_debug_parts: no thinking
				elseif AL and AL.On() then
					AL.Measure("think: decisions and fighting (the rest)", think, npc, now, dt, best, seen, pos)
				else
					think(npc, now, dt, best, seen, pos)
				end
				if npc.NGLDying then -- nothing
				elseif npc.NGLDetail then npc:NGLUpdatePose()
				elseif npc.NGLPosed then npc:NGLResetPose() end

				-- Lag compensation (when the engine compensates NPCs at all)
				-- only near players: far ones aren't recorded every tick.
				if npc.NGLLagDefault then
					local want = best < lagSqr
					if want ~= npc.NGLLagOn then
						npc.NGLLagOn = want
						npc:SetLagCompensated(want)
					end
				end
			end

			if SysTime() - start > budget then
				cursor = idx
				break
			end
		end
	end

	if B then B.LuaTime = B.LuaTime + (SysTime() - start) end
end)

concommand.Add("ngl_status", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	local nCells = 0
	for _ in pairs(cells) do nCells = nCells + 1 end
	local msg = string.format("[NGL] %d NPCs, %d grid cells in use, budget %.1f ms/tick", #List, nCells, cvBudget:GetFloat())
	print(msg)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
end)
