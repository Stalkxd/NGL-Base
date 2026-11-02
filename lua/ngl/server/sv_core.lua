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
local floor, min, abs, random, Rand = math.floor, math.min, math.abs, math.random, math.Rand

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
end)

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
end

function Core.Count() return #List end

----------------------------------------------------------------------------
-- Perception
----------------------------------------------------------------------------

local players = {}

local losTrace = { mask = MASK_SOLID_BRUSHONLY }
local losResult = {}
losTrace.output = losResult

local function canSee(npc, from, ent)
	losTrace.start = from
	losTrace.endpos = ent:WorldSpaceCenter()
	util.TraceLine(losTrace)
	return not losResult.Hit
end

-- Nearest hostile within sight, checking line of sight on at most the 3
-- closest candidates.
local cand, candD = {}, {}
local function findEnemy(npc, pos)
	local range = npc.SightRange
	local rangeSqr = range * range
	local n = 0

	local function consider(ent)
		if ent == npc or not Core.IsHostile(npc, ent) then return end
		local d = pos:DistToSqr(ent:GetPos())
		if d > rangeSqr then return end
		-- insertion into a 3-slot sorted list
		if n < 3 then
			n = n + 1
			cand[n], candD[n] = ent, d
		elseif d < candD[3] then
			cand[3], candD[3] = ent, d
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

	local r = math.ceil(range / CELL)
	local cx, cy = floor(pos.x / CELL) + OFFSET, floor(pos.y / CELL) + OFFSET
	for x = cx - r, cx + r do
		local base = x * 4096
		for y = cy - r, cy + r do
			local c = cells[base + y]
			if c then
				for ent in pairs(c) do consider(ent) end
			end
		end
	end
	for i = 1, #players do consider(players[i]) end

	local eye = pos + Vector(0, 0, npc.EyeHeight)
	local found = nil
	for i = 1, n do
		if not found and canSee(npc, eye, cand[i]) then found = cand[i] end
		cand[i] = nil
	end
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
					end
				end
			end
		end
	end
end

function Core.SetEnemy(npc, enemy)
	local old = npc.NGLEnemy
	if old == enemy then return end
	local now = CurTime()
	npc.NGLEnemy = enemy
	npc.NGLFireAccum = 0
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
		if not IsValid(old) then alertAllies(npc, ePos, now) end
		npc:OnSeeEnemy(enemy)
	else
		npc.NGLEnemy = nil
		npc.NGLGoal = nil
		npc.NGLFace = nil
		npc.NGLHome = npc:GetPos() -- wander around where the fight ended
		npc.NGLNextWander = now + Rand(1, 3)
		if IsValid(old) then npc:OnLoseEnemy(old) end
	end
end

----------------------------------------------------------------------------
-- Combat
----------------------------------------------------------------------------

local shotTrace = { mask = MASK_SHOT }
local shotResult = {}
shotTrace.output = shotResult

local function fire(npc, enemy, shots, visual)
	local w = npc.Weapon
	local src = npc:GetPos() + Vector(0, 0, npc.EyeHeight)
	local dst = enemy:WorldSpaceCenter()

	if visual then
		npc:NGLGesture("Fire")
		local dir = dst - src
		dir:Normalize()
		npc:FireBullets({
			Src = src,
			Dir = dir,
			Spread = Vector(w.Spread, w.Spread, 0),
			Num = shots,
			Damage = w.Damage,
			Tracer = 1,
			Attacker = npc,
			IgnoreEntity = npc,
		})
		if w.Sound then npc:EmitSound(w.Sound) end
		return
	end

	-- Nobody close enough to see it: one silent trace, expected damage.
	shotTrace.start = src
	shotTrace.endpos = dst
	shotTrace.filter = npc
	util.TraceLine(shotTrace)
	if shotResult.Entity == enemy then
		local dmg = DamageInfo()
		dmg:SetDamage(w.Damage * shots * (w.Accuracy or 0.6))
		dmg:SetDamageType(DMG_BULLET)
		dmg:SetAttacker(npc)
		dmg:SetInflictor(npc)
		dmg:SetDamagePosition(shotResult.HitPos)
		enemy:TakeDamageInfo(dmg)
	end
end

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

-- Move towards the enemy. Straight line when it's in view on the same level
-- (no path-finding at all), otherwise along a path from our nav grid,
-- requested in the background. The NPC never stands still waiting: until the
-- path arrives (or if it fails) it keeps walking straight at the target.
local function chase(npc, now, pos, tPos, visible)
	local nav = NGL.Nav
	local forcePath = now < (npc.NGLForcePathUntil or 0)
	if not (nav and nav.Loaded) or now < (npc.NGLPathFailUntil or 0)
		or (visible and not forcePath and abs(tPos.z - pos.z) < 96) then
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
	npc.NGLPathPending = true
	npc.NGLPathPendingSince = now
	npc.NGLRepathAt = now + 3
	local target = Vector(tPos.x, tPos.y, tPos.z)
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
	end)
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

-- No enemy: go and look where an ally saw one, otherwise stroll around home.
local function idle(npc, now, pos)
	npc.NGLFace = nil

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
		return
	end
	if npc.NGLPath or npc.NGLGoal or npc.NGLPathPending then return end -- still strolling
	npc:NGLSetMoveMode("walk")
	npc.NGLDirect = nil
	if now < (npc.NGLNextWander or 0) then return end

	local delay = npc.WanderDelay
	npc.NGLNextWander = now + Rand(delay[1], delay[2])
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

-- One AI decision for one NPC. `dt` is the time since its last think.
local function think(npc, now, dt, nearestPlayerSqr)
	npc.NGLNear = nearestPlayerSqr < cvVisual:GetFloat() ^ 2
	local detailSqr = cvDetail:GetFloat() ^ 2
	npc.NGLDetail = nearestPlayerSqr < (npc.NGLDetail and detailSqr * DETAIL_LEAVE or detailSqr)
	if npc:OnAIThink(dt) == true then return end

	local pos = npc:GetPos()
	gridUpdate(npc, pos)

	-- Stuck (not moved 16 units in 2 s while trying to): drop the path and
	-- strafe goal so the next decision starts fresh.
	if npc.NGLGoal or npc.NGLPath then
		local sp = npc.NGLStuckPos
		if not sp or pos:DistToSqr(sp) >= STUCK_SQR then
			npc.NGLStuckPos, npc.NGLStuckT = pos, now
		elseif now - npc.NGLStuckT > 2 then
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
		local found = findEnemy(npc, pos)
		if found then
			Core.SetEnemy(npc, found)
			npc.NGLLastSeenPos, npc.NGLLastSeenT = found:GetPos(), now
		elseif not enemyOk or now - (npc.NGLLastSeenT or 0) > npc.EnemyMemory then
			-- Dead, gone, or out of sight for too long.
			Core.SetEnemy(npc, nil)
		end
		enemy = npc.NGLEnemy
		enemyOk = IsValid(enemy)
	end

	if not enemyOk then
		idle(npc, now, pos)
		return
	end

	local tPos = enemy:GetPos()

	-- Line of sight to the current enemy, rechecked at most twice a second.
	if now >= (npc.NGLNextVis or 0) then
		npc.NGLNextVis = now + 0.5
		npc.NGLEnemyVisible = canSee(npc, pos + Vector(0, 0, npc.EyeHeight), enemy)
		if npc.NGLEnemyVisible then npc.NGLLastSeenPos, npc.NGLLastSeenT = tPos, now end
	end
	local visible = npc.NGLEnemyVisible

	-- Out of sight: hunt it down where we last saw it (no seeing through walls).
	if not visible then
		local last = npc.NGLLastSeenPos or tPos
		if pos:DistToSqr(last) < LAST_SEEN_DONE_SQR then
			Core.SetEnemy(npc, nil) -- it's not here; look around from here
			idle(npc, now, pos)
			return
		end
		npc:NGLSetMoveMode("run")
		chase(npc, now, pos, last, false)
		npc.NGLNextStrafe = 0
		npc.NGLFireAccum = 0
		npc.NGLFace = nil -- look where we walk
		return
	end

	local distSqr = pos:DistToSqr(tPos)
	local range = npc.AttackRange
	if distSqr > range * range * ATTACK_KEEP_SQR_PAD then
		npc:NGLSetMoveMode("run")
		chase(npc, now, pos, tPos, true)
		npc.NGLNextStrafe = 0
		npc.NGLFireAccum = 0
		npc.NGLFace = tPos
		return
	end

	-- In range and in view: strafe and shoot.
	npc.NGLPath = nil
	npc.NGLDirect = nil
	npc:NGLSetMoveMode("walk")
	if now >= npc.NGLNextStrafe then
		npc.NGLNextStrafe = now + Rand(2, 3.5)
		local dir = tPos - pos
		dir.z = 0
		dir:Normalize()
		local side = (random(2) == 1) and 1 or -1
		npc.NGLGoal = pos + Vector(-dir.y, dir.x, 0) * (side * Rand(100, 250))
	end
	npc.NGLFace = tPos

	local w = npc.Weapon
	if not w then
		npc.NGLFireAccum = 0
		return
	end
	if now < (npc.NGLReloadUntil or 0) then
		npc.NGLFireAccum = 0
		return
	end

	-- Shots owed since the last think. Far-away NPCs think rarely but
	-- still deal the same damage over time.
	local acc = npc.NGLFireAccum + dt
	local shots = floor(acc / w.Delay)
	if shots <= 0 then
		npc.NGLFireAccum = acc
		return
	end
	npc.NGLFireAccum = acc - shots * w.Delay

	local clipSize = w.Clip or 0
	if clipSize > 0 then
		shots = min(shots, npc.NGLClip)
		npc.NGLClip = npc.NGLClip - shots
	end
	local visual = npc.NGLNear
	if shots > 0 then fire(npc, enemy, min(shots, visual and 3 or 30), visual) end

	if clipSize > 0 and npc.NGLClip <= 0 then
		npc.NGLClip = clipSize
		npc.NGLReloadUntil = now + (w.ReloadTime or 2)
		npc.NGLFireAccum = 0
		npc:NGLGesture("Reload")
		npc:OnReload()
	end
end

----------------------------------------------------------------------------
-- Scheduler
----------------------------------------------------------------------------

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
		end
	end
	for i = np + 1, #players do players[i] = nil end

	local nearSqr, midSqr = cvNear:GetFloat() ^ 2, cvMid:GetFloat() ^ 2
	local rNear, rMid, rFar = cvRateNear:GetFloat(), cvRateMid:GetFloat(), cvRateFar:GetFloat()

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
					local d = pos:DistToSqr(players[p]:GetPos())
					if d < best then best = d end
				end

				local interval = (best < nearSqr and rNear) or (best < midSqr and rMid) or rFar
				local dt = now - npc.NGLLastThink
				npc.NGLLastThink = now
				npc.NGLNextThink = now + interval * Rand(0.9, 1.1)

				think(npc, now, dt, best)
				if npc.NGLDying then -- nothing
				elseif npc.NGLDetail then npc:NGLUpdatePose()
				elseif npc.NGLPosed then npc:NGLResetPose() end
			end

			if SysTime() - start > budget then
				cursor = idx
				break
			end
		end
	end

	local B = NGL.Bench
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
