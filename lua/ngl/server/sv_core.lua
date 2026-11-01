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
local floor, min, random, Rand = math.floor, math.min, math.random, math.Rand

local cvBudget = CreateConVar("ngl_ai_budget", "3", FCVAR_ARCHIVE,
	"Max milliseconds of NGL AI decisions per server tick. Leftover NPCs think next tick.", 0.1, 50)
local cvNear = CreateConVar("ngl_ai_near", "1500", FCVAR_ARCHIVE, "Within this distance of a player, NPCs think at the fast rate.", 0, 50000)
local cvMid = CreateConVar("ngl_ai_mid", "4000", FCVAR_ARCHIVE, "Within this distance of a player, NPCs think at the medium rate.", 0, 50000)
local cvRateNear = CreateConVar("ngl_ai_rate_near", "0.1", FCVAR_ARCHIVE, "Seconds between AI thinks near players.", 0, 5)
local cvRateMid = CreateConVar("ngl_ai_rate_mid", "0.3", FCVAR_ARCHIVE, "Seconds between AI thinks at medium distance.", 0, 5)
local cvRateFar = CreateConVar("ngl_ai_rate_far", "1.0", FCVAR_ARCHIVE, "Seconds between AI thinks far from every player.", 0, 10)
local cvVisual = CreateConVar("ngl_ai_visual_range", "3000", FCVAR_ARCHIVE, "NPCs this close to a player fire real bullets with tracers and sound; further away they use one silent trace.", 0, 50000)

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

function Core.SetEnemy(npc, enemy)
	local old = npc.NGLEnemy
	if old == enemy then return end
	npc.NGLEnemy = enemy
	npc.NGLFireAccum = 0
	if IsValid(enemy) then
		npc:OnSeeEnemy(enemy)
	elseif IsValid(old) then
		npc:OnLoseEnemy(old)
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

-- One AI decision for one NPC. `dt` is the time since its last think.
local function think(npc, now, dt, nearestPlayerSqr)
	if npc:OnAIThink(dt) == true then return end

	local pos = npc:GetPos()
	gridUpdate(npc, pos)

	local enemy = npc.NGLEnemy
	local enemyOk = IsValid(enemy) and enemy:Health() > 0 and Core.IsHostile(npc, enemy)

	if not enemyOk or now >= npc.NGLNextRetarget then
		npc.NGLNextRetarget = now + Rand(0.8, 1.2)
		Core.SetEnemy(npc, findEnemy(npc, pos))
		enemy = npc.NGLEnemy
		enemyOk = IsValid(enemy)
	end

	if not enemyOk then
		npc.NGLGoal = nil
		npc.NGLFace = nil
		return
	end

	local tPos = enemy:GetPos()
	local distSqr = pos:DistToSqr(tPos)
	local range = npc.AttackRange
	local rangeSqr = range * range

	if distSqr > rangeSqr * ATTACK_KEEP_SQR_PAD then
		-- Chase. (Straight line for now; step 3 adds our own navigation.)
		npc.NGLGoal = tPos
		npc.NGLNextStrafe = 0
		npc.NGLFireAccum = 0
	else
		if now >= npc.NGLNextStrafe then
			npc.NGLNextStrafe = now + Rand(2, 3.5)
			local dir = tPos - pos
			dir.z = 0
			dir:Normalize()
			local side = (random(2) == 1) and 1 or -1
			npc.NGLGoal = pos + Vector(-dir.y, dir.x, 0) * (side * Rand(100, 250))
		end

		-- Shots owed since the last think. Far-away NPCs think rarely but
		-- still deal the same damage over time.
		local w = npc.Weapon
		local acc = npc.NGLFireAccum + dt
		local shots = w and floor(acc / w.Delay) or 0
		if not w then
			npc.NGLFireAccum = 0
		elseif shots > 0 then
			npc.NGLFireAccum = acc - shots * w.Delay
			local visual = nearestPlayerSqr < cvVisual:GetFloat() ^ 2
			fire(npc, enemy, min(shots, visual and 3 or 30), visual)
		else
			npc.NGLFireAccum = acc
		end
	end

	npc.NGLFace = tPos
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
