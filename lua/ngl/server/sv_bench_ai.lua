-- Shared "battle" logic for the benchmark entities.
--
-- Both test entities (ngl_bench_nextbot and ngl_bench_light) run exactly this
-- decision code, so the benchmark compares the cost of the entity foundation
-- (engine NextBot vs our own lightweight entity), not the cost of the AI.
--
-- The behaviour is deliberately "realistic enough": pick the nearest enemy,
-- walk towards it, and once in range strafe around while shooting.

NGL.Bench = NGL.Bench or {}
local B = NGL.Bench

B.Agents = B.Agents or {}   -- [ent] = true, every live benchmark agent
B.LuaTime = 0               -- seconds of Lua spent in agent code this tick

local ATTACK_RANGE_SQR = 700 * 700
local RETARGET_INTERVAL = 1.0
local FIRE_INTERVAL = 0.5
local EYE_OFFSET = Vector(0, 0, 60)
local CHEST_OFFSET = Vector(0, 0, 40)

B.Model = "models/combine_soldier.mdl"
B.MoveSpeed = 200

local cvFireBullets = CreateConVar("ngl_bench_bullets", "0", FCVAR_ARCHIVE,
	"1 = benchmark agents use FireBullets (tracers, impact effects). 0 = a single line trace per shot.", 0, 1)

util.PrecacheModel(B.Model)

function B.InitAgent(ent)
	local now = CurTime()
	ent.NGLNextRetarget = now + math.Rand(0, RETARGET_INTERVAL) -- stagger so they don't all retarget on one tick
	ent.NGLNextFire = now + math.Rand(0, FIRE_INTERVAL)
	ent.NGLNextStrafe = 0
	ent.NGLTarget = nil
	ent.NGLMoveGoal = nil
	ent.NGLFace = nil
	B.Agents[ent] = true
end

function B.RemoveAgent(ent)
	B.Agents[ent] = nil
end

-- Brute force nearest enemy. Fine at 1 Hz per agent for step 1; the real base
-- replaces this with a spatial grid in step 2.
function B.FindNearestEnemy(ent)
	local myTeam = ent.NGLTeam
	local myPos = ent:GetPos()
	local best, bestDist = nil, math.huge

	for other in pairs(B.Agents) do
		if other.NGLTeam ~= myTeam and IsValid(other) and other:Health() > 0 then
			local d = myPos:DistToSqr(other:GetPos())
			if d < bestDist then
				best, bestDist = other, d
			end
		end
	end

	return best
end

local shotTrace = { mask = MASK_SHOT }
local shotResult = {}
shotTrace.output = shotResult

function B.Fire(ent, target)
	local src = ent:GetPos() + EYE_OFFSET
	local dst = target:GetPos() + CHEST_OFFSET

	if cvFireBullets:GetBool() then
		local dir = dst - src
		dir:Normalize()
		ent:FireBullets({
			Src = src,
			Dir = dir,
			Spread = Vector(0.03, 0.03, 0),
			Num = 1,
			Damage = 4,
			Tracer = 1,
			Attacker = ent,
		})
		return
	end

	shotTrace.start = src
	shotTrace.endpos = dst
	shotTrace.filter = ent
	util.TraceLine(shotTrace)

	if shotResult.Entity == target then
		local dmg = DamageInfo()
		dmg:SetDamage(4)
		dmg:SetDamageType(DMG_BULLET)
		dmg:SetAttacker(ent)
		dmg:SetInflictor(ent)
		dmg:SetDamagePosition(shotResult.HitPos)
		target:TakeDamageInfo(dmg)
	end
end

-- Decide what the agent wants to do this tick.
-- Writes ent.NGLMoveGoal (Vector or nil) and ent.NGLFace (Vector or nil).
function B.ThinkAgent(ent, now)
	local t0 = SysTime()

	if now >= ent.NGLNextRetarget then
		ent.NGLNextRetarget = now + RETARGET_INTERVAL
		ent.NGLTarget = B.FindNearestEnemy(ent)
	end

	local target = ent.NGLTarget
	if not IsValid(target) or target:Health() <= 0 then
		ent.NGLTarget = nil
		ent.NGLMoveGoal = nil
		ent.NGLFace = nil
		B.LuaTime = B.LuaTime + (SysTime() - t0)
		return
	end

	local myPos = ent:GetPos()
	local tPos = target:GetPos()

	if myPos:DistToSqr(tPos) > ATTACK_RANGE_SQR then
		-- Chase.
		ent.NGLMoveGoal = tPos
		ent.NGLNextStrafe = 0
	else
		-- In range: strafe sideways every few seconds and keep shooting.
		if now >= ent.NGLNextStrafe then
			ent.NGLNextStrafe = now + math.Rand(2, 3.5)
			local dir = tPos - myPos
			dir.z = 0
			dir:Normalize()
			local side = (math.random(2) == 1) and 1 or -1
			ent.NGLMoveGoal = myPos + Vector(-dir.y, dir.x, 0) * (side * math.Rand(100, 250))
		end

		local goal = ent.NGLMoveGoal
		if goal and myPos:DistToSqr(goal) < 32 * 32 then
			ent.NGLMoveGoal = nil
		end

		if now >= ent.NGLNextFire then
			ent.NGLNextFire = now + FIRE_INTERVAL + math.Rand(0, 0.1)
			B.Fire(ent, target)
		end
	end

	ent.NGLFace = tPos
	B.LuaTime = B.LuaTime + (SysTime() - t0)
end
