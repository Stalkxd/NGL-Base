-- NGL AI modes: how an NPC fights once it has an enemy.
--
-- Every NPC gets one mode when it spawns, from ENT.AIMode:
--   ENT.AIMode = "flanker"                                -- always this one
--   ENT.AIMode = { balanced = 3, flanker = 2, assault = 1 } -- picked at random, by weight
--
-- Built-in modes:
--   balanced  the default: stands, crouches or sidesteps while shooting,
--             chases what it loses sight of.
--   assault   pushes forward no matter what: runs at the enemy shooting,
--             never crouches or hides, keeps pressing when it loses sight.
--   flanker   attacks from out of your sight: circles round to a spot at
--             your side or back that you can't see, then opens fire, and
--             moves to a new hidden spot after a few seconds.
--   defender  holds the spot where the fight started: crouches, shoots from
--             there, ducks out of sight when hurt, doesn't chase far.
--   ambusher  for NPCs without a gun (fast zombies): never comes at you
--             where you're looking. While you watch it, it runs to a spot
--             at your side or back you can't see, waits there until you
--             look away or come close, then rushes and leaps at you.
--
-- Your own mode (any addon, server side):
--   NGL.RegisterAIMode("sniper", {
--   	StandChance = 0.8, CrouchChance = 0.2,    -- used by the default fight
--   	Fight = function(npc, enemy, dist, visible, now, dt)
--   		-- runs every think while the NPC has an enemy and no order;
--   		-- return true when you handled it, nothing for the default.
--   	end,
--   })
--   ENT.AIMode = "sniper"
-- Fight is called with visible = false while the enemy is out of sight,
-- and with visible = true after the melee check (for NPCs without a gun,
-- before closing in and leaping). Build it from the same
-- blocks the built-in modes use: NGL.Core.Chase, .Shoot, .Strafe,
-- .StopMoving, .FindHiddenSpot, .HiddenFrom, .EyeOf, .FacingYaw, .GridSpot,
-- or the ENT building blocks (self:MoveTo, self:FireWeapon...).
-- Like every NGL hook it runs at the AI rate, never every tick.
--
-- Test in game: ngl_ai_mode <mode> sets the NPC you look at (or every NGL
-- NPC with "all" after it); ngl_ai_mode_override makes new NPCs use one.

NGL.AIModes = NGL.AIModes or {}
local Modes = NGL.AIModes

local IsValid = IsValid
local random, Rand, min, max = math.random, math.Rand, math.min, math.max

local cvOverride = CreateConVar("ngl_ai_mode_override", "", FCVAR_ARCHIVE,
	"Empty: NGL NPCs use their own AI mode. A mode name (balanced, assault, flanker, defender...): every new NGL NPC uses it.")

function NGL.RegisterAIMode(name, def)
	def.Name = name
	Modes[name] = def
	return def
end

-- The mode for a newly spawned NPC.
function NGL.PickAIMode(npc)
	local forced = cvOverride:GetString()
	if forced ~= "" and Modes[forced] then return Modes[forced] end
	local want = npc.AIMode
	if type(want) == "table" then
		local total = 0
		for name, w in pairs(want) do
			if Modes[name] then total = total + w end
		end
		local r = random() * total
		for name, w in pairs(want) do
			if Modes[name] then
				r = r - w
				if r <= 0 then return Modes[name] end
			end
		end
		want = nil
	end
	return Modes[want] or Modes.balanced
end

local function core() return NGL.Core end

----------------------------------------------------------------------------
-- balanced: the default fight (sv_core.lua), no Fight function.
----------------------------------------------------------------------------

NGL.RegisterAIMode("balanced", {})

----------------------------------------------------------------------------
-- assault: push forward no matter what.
----------------------------------------------------------------------------

NGL.RegisterAIMode("assault", {
	StandChance = 0.3,
	CrouchChance = 0,
	Close = 0.3, -- of AttackRange: stops advancing this close

	Fight = function(npc, enemy, dist, visible, now, dt)
		if not npc.Weapon then return end -- melee NPCs already charge
		local Core = core()
		local pos, tPos = npc:GetPos(), enemy:GetPos()
		npc.NGLCrouch = false
		if not visible then
			-- Keep pressing: to where it was last seen, then where it went,
			-- for as long as it remembers the enemy.
			local last = npc.NGLLastSeenPos or tPos
			local goal = pos:DistToSqr(last) < 150 * 150 and tPos or last
			npc:NGLSetMoveMode("run")
			Core.Chase(npc, now, pos, goal, false)
			npc.NGLFace = nil
			npc.NGLFireAccum = 0
			return true
		end
		local close = max(npc.AttackRange * 0.3, 250)
		if dist > close then
			-- Run straight at it, shooting on the way.
			npc:NGLSetMoveMode("run")
			Core.Chase(npc, now, pos, tPos, true)
			npc.NGLFace = tPos
			npc.NGLNextStrafe = 0
			if dist < npc.AttackRange * 1.2 then Core.Shoot(npc, now, dt, enemy) else npc.NGLFireAccum = 0 end
			return true
		end
		-- Up close: short steps, never backing off.
		Core.Strafe(npc, now, pos, tPos, 0.4, 0, 50, 120)
		Core.Shoot(npc, now, dt, enemy)
		return true
	end,
})

----------------------------------------------------------------------------
-- flanker: attack from out of the enemy's sight.
----------------------------------------------------------------------------

-- Spots at the enemy's sides and back, 450..800 units from it.
local FLANK_YAWS = { 100, -100, 135, -135, 165, -165 }
local flankYaws = {}

local function findFlank(npc, enemy)
	local Core = core()
	local face = Core.FacingYaw(enemy)
	for i, a in ipairs(FLANK_YAWS) do flankYaws[i] = face + a end
	-- a new spot each time, not the one it is standing on
	return Core.FindHiddenSpot(npc, Core.EyeOf(enemy), enemy:GetPos(), 450, 800, flankYaws, npc:GetPos())
end

NGL.RegisterAIMode("flanker", {
	StandChance = 0.3,
	CrouchChance = 0.3,
	AttackTime = { 4, 7 }, -- seconds of shooting before moving to a new spot
	MoveTime = 12,         -- seconds to reach a spot before giving up on it

	Fight = function(npc, enemy, dist, visible, now, dt)
		if not npc.Weapon then return end
		local Core = core()
		local mode = npc.NGLMode
		local pos, tPos = npc:GetPos(), enemy:GetPos()
		local F = npc.NGLFlank
		if F and F.enemy ~= enemy then F = nil end

		if F and F.phase == "attack" then
			if now < F.untilT then
				if visible then
					Core.Strafe(npc, now, pos, tPos, mode.StandChance, mode.CrouchChance, 60, 150)
					Core.Shoot(npc, now, dt, enemy)
				else
					-- Peek: step towards it until it's in view again.
					npc.NGLCrouch = false
					npc:NGLSetMoveMode("walk")
					Core.Chase(npc, now, pos, npc.NGLLastSeenPos or tPos, false)
					npc.NGLFace = nil
					npc.NGLFireAccum = 0
				end
				return true
			end
			F = nil -- been here long enough: move
		end

		if not F then
			if now < (npc.NGLNextFlank or 0) then
				npc.NGLFlank = nil
				return -- nowhere to hide right now: fight normally
			end
			npc.NGLNextFlank = now + 3
			local spot = findFlank(npc, enemy)
			if not spot then
				npc.NGLFlank = nil
				return
			end
			F = { enemy = enemy, phase = "move", spot = spot, untilT = now + (mode.MoveTime or 12) }
			npc.NGLFlank = F
			Core.StopMoving(npc)
		end

		-- Moving to the hidden spot: run there along the grid, quiet.
		if pos:DistToSqr(F.spot) < 96 * 96 or now > F.untilT then
			local t = mode.AttackTime or { 4, 7 }
			F.phase, F.untilT = "attack", now + Rand(t[1], t[2])
			Core.StopMoving(npc)
			return true
		end
		npc.NGLCrouch = false
		npc:NGLSetMoveMode("run")
		Core.Chase(npc, now, pos, F.spot, false)
		npc.NGLFace = nil
		npc.NGLFireAccum = 0
		-- Caught in the open close by: shoot back on the way.
		if visible and dist < npc.AttackRange * 0.5 then
			npc.NGLFace = tPos
			Core.Shoot(npc, now, dt, enemy)
		end
		return true
	end,
})

----------------------------------------------------------------------------
-- defender: hold the ground where the fight started.
----------------------------------------------------------------------------

NGL.RegisterAIMode("defender", {
	StandChance = 0.4,
	CrouchChance = 0.6,
	Leash = 500,        -- never further than this from where the fight started
	HurtCover = 0.5,    -- below this share of health it ducks out of sight
	CoverTime = { 3, 5 },

	Fight = function(npc, enemy, dist, visible, now, dt)
		if not npc.Weapon then return end
		local Core = core()
		local mode = npc.NGLMode
		local pos, tPos = npc:GetPos(), enemy:GetPos()
		local home = npc.NGLContactPos or pos
		local leash = npc.DefendRadius or mode.Leash or 500
		local leashSqr = leash * leash

		-- Hurt: duck out of sight for a few seconds, then come back out.
		local C = npc.NGLCover
		if C and now < C.untilT then
			if pos:DistToSqr(C.spot) > 64 * 64 then
				npc.NGLCrouch = false
				npc:NGLSetMoveMode("run")
				Core.Chase(npc, now, pos, C.spot, pos:DistToSqr(C.spot) < 300 * 300)
				npc.NGLFace = nil
			else
				Core.StopMoving(npc)
				npc.NGLCrouch = npc.NGLActs.CrouchIdle ~= nil
				npc.NGLFace = npc.NGLLastSeenPos
			end
			npc.NGLFireAccum = 0
			return true
		end
		npc.NGLCover = nil
		if visible and now >= (npc.NGLNextCover or 0) and npc:Health() < npc:GetMaxHealth() * (mode.HurtCover or 0.5) then
			-- Nowhere to hide: look again in a while. Each look is up to 24
			-- traces, and on open ground a hurt defender found nothing every
			-- time, so 2 s made defenders (many of the rebels) costly.
			npc.NGLNextCover = now + 5
			local spot = Core.FindHiddenSpot(npc, Core.EyeOf(enemy), home, 120, leash)
			if spot then
				npc.NGLNextCover = now + 12
				local t = mode.CoverTime or { 3, 5 }
				npc.NGLCover = { spot = spot, untilT = now + Rand(t[1], t[2]) }
				Core.StopMoving(npc)
				return true
			end
		end

		if not visible then
			-- Don't chase: back to our ground, watch where it was last seen.
			if pos:DistToSqr(home) > leashSqr then
				npc.NGLCrouch = false
				npc:NGLSetMoveMode("run")
				Core.Chase(npc, now, pos, home, false)
				npc.NGLFace = nil
			else
				if npc.NGLGoal or npc.NGLPath or npc.NGLPathPending then Core.StopMoving(npc) end
				npc.NGLCrouch = npc.NGLActs.CrouchIdle ~= nil
				npc.NGLFace = npc.NGLLastSeenPos
			end
			npc.NGLFireAccum = 0
			return true
		end

		-- In view: shoot from our ground, even a bit beyond the usual range.
		if pos:DistToSqr(home) > leashSqr then
			npc.NGLCrouch = false
			npc:NGLSetMoveMode("walk")
			Core.Chase(npc, now, pos, home, true)
			npc.NGLFace = tPos
		else
			Core.Strafe(npc, now, pos, tPos, mode.StandChance, mode.CrouchChance, 40, 100, home, leash)
		end
		if dist < npc.AttackRange * 1.5 then Core.Shoot(npc, now, dt, enemy) else npc.NGLFireAccum = 0 end
		return true
	end,
})

----------------------------------------------------------------------------
-- ambusher: melee NPCs that come at you from out of sight.
----------------------------------------------------------------------------

-- Spots at the enemy's sides and back.
local AMBUSH_YAWS = { 90, -90, 125, -125, 160, -160, 180 }
local ambushYaws = {}
local sqrt, cos, sin, rad = math.sqrt, math.cos, math.sin, math.rad

-- Is `enemy` looking our way (within about 55 degrees)? Math only.
local function watching(enemy, pos)
	local Core = core()
	local eye = Core.EyeOf(enemy)
	local dx, dy = pos.x - eye.x, pos.y - eye.y
	local l = sqrt(dx * dx + dy * dy)
	if l < 1 then return true end
	local r = rad(Core.FacingYaw(enemy))
	return (dx * cos(r) + dy * sin(r)) / l > 0.57
end

NGL.RegisterAIMode("ambusher", {
	Strike = 420,          -- this close: rush in whatever it's looking at
	HideMin = 300,         -- hiding spots this far from the enemy
	HideMax = 650,
	WaitTime = { 1.5, 4 }, -- seconds waiting in hiding at most
	MoveTime = 8,          -- seconds to reach a hiding spot before giving up on it
	RushTime = 5,          -- seconds of rushing before it may hide again
	HideDelay = 6,         -- seconds between looking for hiding spots

	Fight = function(npc, enemy, dist, visible, now, dt)
		if npc.Weapon then return end -- gunmen: see flanker
		local Core = core()
		local mode = npc.NGLMode
		local pos, tPos = npc:GetPos(), enemy:GetPos()
		local A = npc.NGLAmbush
		if A and A.enemy ~= enemy then A = nil end

		-- In leap range and in view: leap, whether or not the enemy is
		-- looking at it (hiding is for getting close, not for this).
		local lp = npc.LeapAttack
		if visible and lp and NGL.Leap and NGL.Leap.Can(npc, enemy, dist, now, lp) then
			npc.NGLAmbush = { enemy = enemy, phase = "rush", untilT = now + (mode.RushTime or 5) }
			if npc:OnAttack(enemy, "leap") ~= true then NGL.Leap.Start(npc, enemy, lp, now) end
			return true
		end

		-- Close: go for it (the default leaps and claws).
		if dist < (mode.Strike or 420) then
			if not A or A.phase ~= "rush" then
				npc.NGLAmbush = { enemy = enemy, phase = "rush", untilT = now + (mode.RushTime or 5) }
			end
			return
		end

		if A and A.phase == "rush" then
			if now < A.untilT then
				if visible then return end
				-- Lost sight while rushing: it still knows where you went.
				npc:NGLSetMoveMode("run")
				Core.Chase(npc, now, pos, tPos, false)
				npc.NGLFace = nil
				return true
			end
			A = nil
		end

		if not A then
			npc.NGLAmbush = nil
			if not visible then return end -- hunt where it was last seen
			if now < (npc.NGLNextAmbush or 0) or not watching(enemy, pos) then
				-- Not looking our way (or we only just hid): rush now.
				npc.NGLAmbush = { enemy = enemy, phase = "rush", untilT = now + (mode.RushTime or 5) }
				return
			end
			npc.NGLNextAmbush = now + (mode.HideDelay or 6)
			local face = Core.FacingYaw(enemy)
			for i, a in ipairs(AMBUSH_YAWS) do ambushYaws[i] = face + a end
			local spot = Core.FindHiddenSpot(npc, Core.EyeOf(enemy), tPos, mode.HideMin or 300, mode.HideMax or 650, ambushYaws)
			if not spot then
				npc.NGLAmbush = { enemy = enemy, phase = "rush", untilT = now + (mode.RushTime or 5) }
				return
			end
			A = { enemy = enemy, phase = "move", spot = spot, from = tPos, untilT = now + (mode.MoveTime or 8) }
			npc.NGLAmbush = A
			Core.StopMoving(npc)
		end

		-- The enemy moved far from where we planned round: plan again.
		if A.from:DistToSqr(tPos) > 500 * 500 then
			npc.NGLAmbush, npc.NGLNextAmbush = nil, 0
			return
		end
		npc.NGLLastSeenT = now -- it keeps track of you while it hides

		if A.phase == "move" then
			if pos:DistToSqr(A.spot) < 80 * 80 or now > A.untilT then
				local w = mode.WaitTime or { 1.5, 4 }
				A.phase, A.untilT = "wait", now + Rand(w[1], w[2])
				Core.StopMoving(npc)
				return true
			end
			npc.NGLCrouch = false
			npc:NGLSetMoveMode("run")
			Core.Chase(npc, now, pos, A.spot, false)
			npc.NGLFace = nil
			return true
		end

		-- Waiting out of sight: go when it looks away or time's up.
		if now >= A.untilT or not watching(enemy, pos) then
			npc.NGLAmbush = { enemy = enemy, phase = "rush", untilT = now + (mode.RushTime or 5) }
			npc:NGLSound("Alert", true)
			npc:NGLSetMoveMode("run")
			Core.Chase(npc, now, pos, tPos, visible)
			return true
		end
		if npc.NGLGoal or npc.NGLPath or npc.NGLPathPending then Core.StopMoving(npc) end
		npc.NGLFace = tPos
		return true
	end,
})

----------------------------------------------------------------------------
-- Test command
----------------------------------------------------------------------------

-- ngl_ai_mode <mode> [all]: the NGL NPC you look at (or all of them) fights
-- in this mode from now on.
concommand.Add("ngl_ai_mode", function(ply, _, args)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	local function say(msg)
		print(msg)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
	end
	local mode = Modes[args[1] or ""]
	if not mode then
		local names = {}
		for name in pairs(Modes) do names[#names + 1] = name end
		table.sort(names)
		return say("[NGL] Modes: " .. table.concat(names, ", "))
	end
	local n = 0
	if args[2] == "all" then
		for _, npc in ipairs(NGL.Core.List) do
			if IsValid(npc) then npc.NGLMode = mode; n = n + 1 end
		end
	elseif IsValid(ply) then
		local e = ply:GetEyeTrace().Entity
		if IsValid(e) and e.IsNGLNPC then e.NGLMode = mode; n = 1 end
	end
	say(string.format("[NGL] %d NPC(s) now fight as %s.", n, mode.Name))
end)
