-- Engine projectiles against NGL NPCs.
--
-- The AR2's energy ball (prop_combine_ball) kills HL2's NPCs and flies on
-- through them, but it only does that for engine NPCs (IsNPC): it bounced
-- off NGL NPCs (NextBots) as if they were walls. Here it does what it does
-- in HL2: whatever NGL NPC it touches is dissolved and the ball keeps going.
-- Vehicles (the APC) still stop it, as in HL2.
--
-- Cost: nothing while no ball is in the air. With one, a grid lookup round
-- it each tick (NGL.FindInRadius) and one distance check per NPC found.
-- There are rarely more than a couple of balls at once.

NGL.PhysProj = NGL.PhysProj or {}
local PP = NGL.PhysProj
PP.Balls = PP.Balls or {}

local IsValid = IsValid
local BALL_RADIUS = 12 -- the AR2 ball's size (the engine's is 10, a bit more for the touch)

local function attackerOf(ball)
	local o = ball:GetOwner()
	if IsValid(o) then return o end
	if ball.GetPhysicsAttacker then
		local a = ball:GetPhysicsAttacker(5)
		if IsValid(a) then return a end
	end
	return ball
end

-- Dissolves `npc` (an NGL NPC the ball touched). True if it did.
function PP.BallHit(ball, npc)
	if not (IsValid(npc) and npc.IsNGLNPC) or npc.NGLDying or npc.IsVehicleNPC then return false end
	local dmg = DamageInfo()
	dmg:SetDamage(math.max(npc:Health(), 1) + 1000)
	dmg:SetDamageType(bit.bor(DMG_DISSOLVE, DMG_SHOCK))
	dmg:SetAttacker(attackerOf(ball))
	dmg:SetInflictor(ball)
	dmg:SetDamagePosition(ball:GetPos())
	local v = ball:GetVelocity()
	dmg:SetDamageForce(v * 20)
	npc:TakeDamageInfo(dmg)
	return true
end

local function track(ball)
	if not IsValid(ball) or PP.Balls[ball] then return end
	PP.Balls[ball] = true
	-- Touched one before the tick check got it: it would bounce off, so put
	-- its speed back on the next tick (physics can't be changed inside the
	-- collision callback).
	ball:AddCallback("PhysicsCollide", function(b, data)
		local e = data.HitEntity
		if IsValid(e) and e.IsNGLNPC and not e.IsVehicleNPC then
			PP.BallHit(b, e)
			local v = data.OurOldVelocity
			timer.Simple(0, function()
				if not IsValid(b) then return end
				local phys = b:GetPhysicsObject()
				if IsValid(phys) then phys:SetVelocity(v) end
			end)
		end
	end)
end

hook.Add("OnEntityCreated", "NGL.CombineBall", function(e)
	if e:GetClass() ~= "prop_combine_ball" then return end
	timer.Simple(0, function() track(e) end) -- its physics exist from the next tick
end)

hook.Add("Tick", "NGL.CombineBall", function()
	if not next(PP.Balls) then return end
	local dt = engine.TickInterval()
	for ball in pairs(PP.Balls) do
		if not IsValid(ball) then
			PP.Balls[ball] = nil
		else
			local pos = ball:GetPos()
			local v = ball:GetVelocity()
			-- What it will reach this tick: a bit ahead along its way.
			local reach = BALL_RADIUS + v:Length() * dt
			local ahead = pos + v * (dt * 0.5)
			for _, npc in ipairs(NGL.FindInRadius(ahead, reach + 96)) do
				if not npc.IsVehicleNPC then
					local np = npc:NearestPoint(ahead)
					if np:DistToSqr(ahead) < reach * reach then PP.BallHit(ball, npc) end
				end
			end
		end
	end
end)
