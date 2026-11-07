-- NGL zombies and their headcrabs.
--
-- A zombie with ENT.Headcrab drops a live headcrab of that class when it
-- dies, like in HL2: not when the killing blow hit the head (the crab dies
-- with it) or blew it up. The crab bodygroup (ENT.HeadcrabBodygroup) is
-- taken off the body so the ragdoll is bare. The poison zombie also throws
-- the crabs it carries on its back (ngl_zombie_poison.lua) through
-- Zombie.SpawnCrab.
--
-- A battle of 200 zombies would make 200 more NPCs as they die, so the crabs
-- alive at once that came off zombies are capped (ngl_headcrab_max); over
-- the cap no crab comes off.

NGL.Zombie = NGL.Zombie or {}
local Z = NGL.Zombie

local cvCrabs = CreateConVar("ngl_zombie_headcrabs", "1", FCVAR_ARCHIVE,
	"NGL zombies drop a live headcrab when they die (and poison zombies throw theirs). 0 = never.", 0, 1)
local cvMax = CreateConVar("ngl_headcrab_max", "60", FCVAR_ARCHIVE,
	"Most headcrabs from NGL zombies alive at once; over this no more come off.", 0, 1000)

Z.Live = Z.Live or {}

function Z.CrabCount()
	local n = 0
	for e in pairs(Z.Live) do
		if IsValid(e) and not e.NGLDying then n = n + 1 else Z.Live[e] = nil end
	end
	return n
end

function Z.CanSpawnCrab()
	return cvCrabs:GetBool() and Z.CrabCount() < cvMax:GetInt()
end

-- Shows or hides the crab riding on a zombie's head.
function Z.ShowCrab(npc, on)
	local bg = npc.HeadcrabBodygroup
	if bg and bg < npc:GetNumBodyGroups() then npc:SetBodygroup(bg, on and 1 or 0) end
end

-- A headcrab of `class` at `pos`, after `enemy`. opts.throwTo: thrown from
-- `pos` to land there, opts.time seconds in the air (it lands and goes for
-- the enemy); opts.leap = false: waits a second before its first leap.
-- Returns the crab, or nil over the cap.
function Z.SpawnCrab(class, pos, yaw, enemy, opts)
	if not Z.CanSpawnCrab() then return nil end
	local crab = ents.Create(class)
	if not IsValid(crab) then return nil end
	crab:SetPos(pos)
	crab:SetAngles(Angle(0, yaw or 0, 0))
	crab:Spawn()
	crab:Activate()
	Z.Live[crab] = true
	crab.NGLCrabT = CurTime()
	opts = opts or {}
	-- Next tick, once its locomotion is running.
	timer.Simple(0, function()
		if not IsValid(crab) or crab.NGLDying then return end
		local now = CurTime()
		if IsValid(enemy) and NGL.Core.IsHostile(crab, enemy) then NGL.Core.SetEnemy(crab, enemy) end
		if opts.throwTo then
			local v = NGL.Leap.Ballistic(crab:GetPos(), opts.throwTo, crab.loco:GetGravity(), opts.time or 1)
			NGL.Leap.Start(crab, IsValid(enemy) and enemy or opts.throwTo, crab.LeapAttack, now, { vel = v })
		elseif opts.leap == false then
			crab.NGLNextLeap = now + 1
		end
	end)
	return crab
end

-- Where a crab of `class` fits coming off a zombie standing at `pos`: as
-- high up its body as there's room for, never inside a wall, a prop or the
-- floor. A crab spawned overlapping a wall was stuck there, and bullets hit
-- the wall in front of it: it looked invincible.
local fitTrace = { mask = MASK_NPCSOLID, collisiongroup = COLLISION_GROUP_NPC_SCRIPTED, output = {} }
local function crabSpot(class, npc, pos, height)
	local stored = scripted_ents.GetStored(class)
	local hull = stored and stored.t and stored.t.Hull
	local mins = hull and hull[1] or Vector(-12, -12, 0)
	local maxs = hull and hull[2] or Vector(12, 12, 20)
	local t = fitTrace
	t.start = pos + Vector(0, 0, 4)
	t.endpos = pos + Vector(0, 0, math.max(4, height))
	t.mins, t.maxs = mins, maxs
	t.filter = npc
	local tr = util.TraceHull(t)
	if tr.StartSolid then return nil end -- not even room on the ground
	return tr.HitPos
end

-- The crab comes off a dying zombie (ENT:OnKilled). It's spawned on the next
-- tick, once the zombie's death is done, not in the middle of the damage
-- that killed it; the crab on its head is taken off the body now, so the
-- ragdoll is made without it.
local HEAD_BAND = 14 -- damage this close to the top of the head is a head shot
function Z.OnKilled(npc, dmginfo)
	if not npc.Headcrab then return end
	if dmginfo:IsDamageType(DMG_BLAST) or dmginfo:IsDamageType(DMG_DISSOLVE) then return end
	local pos = npc:GetPos()
	local hp = dmginfo:GetDamagePosition()
	local top = pos.z + (npc.EyeHeight or 60) + 6
	if hp and hp ~= vector_origin and hp.z > top - HEAD_BAND and hp:Distance2DSqr(pos) < 40 * 40 then
		return -- shot in the head: the crab died too (it stays on the body)
	end
	if not Z.CanSpawnCrab() then return end
	local spot = crabSpot(npc.Headcrab, npc, pos, (npc.EyeHeight or 60) - 8)
	if not spot then return end -- nowhere it fits: it died with the zombie
	Z.ShowCrab(npc, false)
	local class, yaw, enemy = npc.Headcrab, npc:GetAngles().y, npc.NGLEnemy
	timer.Simple(0, function()
		Z.SpawnCrab(class, spot, yaw, enemy, { leap = false })
	end)
end


----------------------------------------------------------------------------
-- Crabs that can't be killed (0.32.2)
--
-- A crab coming off a zombie in a horde near a player could now and then
-- not be killed: shots went past it or hit something in front of it. Fitting
-- its spawn spot (0.26.4) wasn't enough, and the exact cause wasn't caught
-- in game, so instead of guessing one more cause, two checks make sure any
-- crab people can see and shoot dies:
--
-- 1. Stuck check. For STUCK_TIME seconds after it appears (and while it
--    leaps), every STUCK_EVERY seconds: is its box inside a wall, a prop or
--    the floor? Then it's moved to the nearest free spot around it, or, with
--    none, killed.
-- 2. Player shots near a crab hit it. After each bullet a player fires
--    (PostEntityFireBullets), a crab whose middle is within SHOT_RADIUS of
--    the bullet's path, before what the bullet hit, takes the bullet's
--    damage, unless the bullet already hit it. Only the crabs that came off
--    zombies are checked (at most ngl_headcrab_max), so it costs a few
--    distance checks a shot.
----------------------------------------------------------------------------

local STUCK_TIME = 3
local STUCK_EVERY = 0.25
local SHOT_RADIUS = 14
-- Walls, the floor and props; not NPCs or players (NGL NPCs walk through
-- each other, so a crab overlapping a zombie isn't stuck).
local stuckCrab
local function stuckFilter(e)
	return e ~= stuckCrab and not (e:IsPlayer() or e:IsNPC() or e:IsNextBot())
end
local stuckTrace = { mask = MASK_NPCSOLID, filter = stuckFilter, output = {} }
local stuckOut = stuckTrace.output
local OFFSETS = {
	Vector(0, 0, 8), Vector(16, 0, 4), Vector(-16, 0, 4), Vector(0, 16, 4), Vector(0, -16, 4),
	Vector(24, 24, 8), Vector(-24, 24, 8), Vector(24, -24, 8), Vector(-24, -24, 8), Vector(0, 0, 24),
}

local function boxStuck(crab, pos)
	local t = stuckTrace
	t.start, t.endpos = pos, pos
	t.mins, t.maxs = crab:OBBMins(), crab:OBBMaxs()
	stuckCrab = crab
	util.TraceHull(t)
	return stuckOut.StartSolid
end

local function unstick(crab)
	local pos = crab:GetPos()
	if not boxStuck(crab, pos) then return end
	for _, o in ipairs(OFFSETS) do
		local p = pos + o
		if not boxStuck(crab, p) then
			crab:SetPos(p)
			return
		end
	end
	-- Nowhere free round it: it's gone, rather than left unkillable.
	local d = DamageInfo()
	d:SetDamage(crab:Health() + 100)
	d:SetDamageType(DMG_GENERIC)
	d:SetAttacker(game.GetWorld())
	d:SetInflictor(game.GetWorld())
	crab:TakeDamageInfo(d)
end

local nextStuck = 0
hook.Add("Tick", "NGL.Zombie.CrabStuck", function()
	local now = CurTime()
	if now < nextStuck or next(Z.Live) == nil then return end
	nextStuck = now + STUCK_EVERY
	for crab in pairs(Z.Live) do
		if IsValid(crab) and not crab.NGLDying
			and (now - (crab.NGLCrabT or 0) < STUCK_TIME or crab.NGLLeapState) then
			unstick(crab)
		end
	end
end)

hook.Add("PostEntityFireBullets", "NGL.Zombie.CrabShots", function(ent, data)
	if not (IsValid(ent) and ent:IsPlayer()) or next(Z.Live) == nil then return end
	local tr = data.Trace
	if not tr then return end
	local a, b = tr.StartPos, tr.HitPos
	if not a or not b then return end
	local dir = b - a
	local len = dir:Length()
	if len < 1 then return end
	dir:Div(len)
	local best, bestAlong
	for crab in pairs(Z.Live) do
		if IsValid(crab) and not crab.NGLDying and crab ~= tr.Entity then
			local c = crab:WorldSpaceCenter()
			local along = (c - a):Dot(dir)
			-- Before what the bullet hit (a crab half inside the wall it hit
			-- counts), and close to its path.
			if along > 0 and along < len + SHOT_RADIUS and (not bestAlong or along < bestAlong)
				and (a + dir * along):DistToSqr(c) < SHOT_RADIUS * SHOT_RADIUS then
				best, bestAlong = crab, along
			end
		end
	end
	if not best then return end
	-- HL2's own guns leave Damage at 0: their ammo type says how much.
	local dmg = data.Damage or 0
	if dmg <= 0 and data.AmmoType then
		local id = game.GetAmmoID(data.AmmoType)
		dmg = id and id >= 0 and game.GetAmmoPlayerDamage(id) or 0
	end
	local d = DamageInfo()
	d:SetDamage(dmg > 0 and dmg or 5)
	d:SetDamageType(DMG_BULLET)
	d:SetAttacker(ent)
	local wep = ent:GetActiveWeapon()
	d:SetInflictor(IsValid(wep) and wep or ent)
	d:SetDamagePosition(a + dir * bestAlong)
	d:SetDamageForce(dir * (data.Force or 1) * 100)
	best:TakeDamageInfo(d)
end)
