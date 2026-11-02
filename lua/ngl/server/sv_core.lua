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
	if npc.NGLSquad then npc.NGLSquad:Remove(npc) end
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

local shotTrace = { mask = MASK_SHOT }
local shotResult = {}
shotTrace.output = shotResult

-- Deals damage from an NGL NPC (melee hits, custom attacks).
function Core.Damage(attacker, target, amount, dmgType, pos, force)
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
local function fire(npc, enemy, shots, visual, dst)
	local w = npc.Weapon
	local src, att
	if visual and npc.NGLMuzzle then src, att = npc:NGLMuzzle() end
	src = src or npc:GetPos() + Vector(0, 0, eyeHeight(npc))
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
		local dir = dst - src
		dir:Normalize()
		npc:FireBullets({
			Src = src,
			Dir = dir,
			Spread = Vector(w.Spread, w.Spread, 0),
			Num = shots,
			Damage = w.Damage,
			Tracer = 1,
			TracerName = w.Tracer,
			Attacker = npc,
			IgnoreEntity = npc,
		})
		if w.MuzzleEffect then
			local ed = EffectData()
			ed:SetEntity(npc)
			ed:SetAttachment(att or 1)
			ed:SetOrigin(src)
			ed:SetAngles(dir:Angle())
			ed:SetScale(1)
			util.Effect(w.MuzzleEffect, ed)
		end
		if w.Sound then npc:EmitSound(w.Sound) end
		return
	end

	-- Nobody close enough to see it: one silent trace, expected damage.
	shotTrace.start = src
	shotTrace.endpos = dst
	shotTrace.filter = npc
	util.TraceLine(shotTrace)
	local hit = shotResult.Entity
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
	if npc:OnAttack(enemy or dst, "ranged") == true then return end

	local clipSize = w.Clip or 0
	if clipSize > 0 then
		shots = min(shots, npc.NGLClip)
		npc.NGLClip = npc.NGLClip - shots
	end
	local visual = npc.NGLNear
	if shots > 0 then fire(npc, enemy, min(shots, visual and 3 or 30), visual, dst) end

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

-- Starts a swing at `target`. The blow lands HitDelay seconds later (the NPC
-- thinks again right then), if the target is still in reach and in front.
function Core.StartMelee(npc, target, now)
	local m = npc.Melee
	if not m or not IsValid(target) then return false end
	npc.NGLNextMelee = now + (m.Delay or 1.5)
	npc.NGLMeleeTarget = target
	npc.NGLMeleeHitAt = now + (m.HitDelay or 0.4)
	Core.StopMoving(npc)
	npc.NGLCrouch = false
	npc.NGLFace = target:GetPos()
	local dur = npc:NGLPlayMeleeAnim() or m.Duration or 1
	npc.NGLBusyUntil = max(npc.NGLBusyUntil or 0, now + dur)
	npc:NGLSound("Attack")
	if npc.NGLNextThink and npc.NGLNextThink > npc.NGLMeleeHitAt then npc.NGLNextThink = npc.NGLMeleeHitAt end
	return true
end

local function resolveMelee(npc)
	local m = npc.Melee
	local t = npc.NGLMeleeTarget
	npc.NGLMeleeHitAt, npc.NGLMeleeTarget = nil, nil
	if not m or not IsValid(t) or (t.NGLDying) then return end

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
	end, npc.NavWidth)
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
		L = { untilT = now + Rand(3, 7), from = pos }
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
			local goal = pos + step * side
			if home and leash and goal:DistToSqr(home) > leash * leash then
				goal = pos - step * side
				if goal:DistToSqr(home) > leash * leash then goal = nil end
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

-- Returns true when it moved the NPC (or kept it in place) as a follower.
function Core.Follow(npc, now, pos, sq)
	local leader = sq.leader
	local slot = sq.slots[npc]
	if not (slot and IsValid(leader) and leader ~= npc) or leader.NGLDying then return false end
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
	if npc:OnOrder(order) == true then return true end -- handled by the NPC itself
	if npc.NGLOrder then Core.EndOrder(npc, "replaced") end
	order.untilT = now + (order.time or base or 10)
	order.startT = now
	npc.NGLOrder = order
	npc.NGLFireAccum = 0
	stopMoving(npc)
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
local function think(npc, now, dt, nearestPlayerSqr)
	npc.NGLNear = nearestPlayerSqr < cvVisual:GetFloat() ^ 2
	local detailSqr = cvDetail:GetFloat() ^ 2
	npc.NGLDetail = nearestPlayerSqr < (npc.NGLDetail and detailSqr * DETAIL_LEAVE or detailSqr)
	if npc.NGLMeleeHitAt and now >= npc.NGLMeleeHitAt then resolveMelee(npc) end
	if npc:OnAIThink(dt) == true then return end
	if now < (npc.NGLBusyUntil or 0) then -- mid-swing or playing a locked animation
		gridUpdate(npc, npc:GetPos())
		return
	end

	local pos = npc:GetPos()
	gridUpdate(npc, pos)

	-- Squad leaders (ENT.Squad): recruiting and commanding, twice a second.
	if npc.Squad then NGL.Squad.LeaderThink(npc, now, pos) end

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

	-- Line of sight to the current enemy, rechecked at most twice a second.
	local tPos = enemyOk and enemy:GetPos()
	if enemyOk and now >= (npc.NGLNextVis or 0) then
		npc.NGLNextVis = now + 0.5
		npc.NGLEnemyVisible = canSee(npc, pos + Vector(0, 0, eyeHeight(npc)), enemy)
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
	if m and distSqr < reach * reach and abs(tPos.z - pos.z) < 72 and now >= (npc.NGLNextMelee or 0) then
		if npc:OnAttack(enemy, "melee") ~= true then Core.StartMelee(npc, enemy, now) end
		return
	end

	local w = npc.Weapon
	if not w then
		-- Melee only: close in (straight, since we can see it) and wait for the next swing.
		npc:NGLSetMoveMode("run")
		npc.NGLFace = tPos
		npc.NGLDirect = true
		if m and distSqr < (reach * 0.8) ^ 2 then
			npc.NGLPath, npc.NGLGoal = nil, nil
		else
			chase(npc, now, pos, tPos, true)
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
