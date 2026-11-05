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

-- Rockets and grenades against vehicles (the APC).
--
-- A NextBot's collision box can't turn and is square, so the APC's is a
-- 160 x 160 box in its middle: HL2's RPG rocket (and the SMG grenade)
-- flew through its nose, its back end and the turret as if they weren't
-- there. Each tick, every such projectile in the air is checked against
-- the box of each vehicle's model, turned with it; one that would go into
-- it this tick goes off right there, as if it hit the model.
--
-- Projectiles: HL2's rpg_missile, apc_missile and grenade_ar2 explode
-- (their own damage, a 200 radius blast), crossbow_bolt hits for its
-- damage, and addon projectiles whose class has "rocket" or "missile" in
-- it are touched against the vehicle (their own code explodes them) or,
-- with no touch code, explode like the RPG's. Cost: nothing while no
-- vehicle or no projectile exists.

local EXPLODE = { rpg_missile = true, apc_missile = true, grenade_ar2 = true }
local BOLT = { crossbow_bolt = true }
PP.Vehicles = PP.Vehicles or {}
PP.Shots = PP.Shots or {}

local function isShot(cls)
	return EXPLODE[cls] or BOLT[cls] or string.find(cls, "rocket", 1, true) ~= nil or string.find(cls, "missile", 1, true) ~= nil
end

-- A vehicle NPC spawned (ngl_apc's OnSpawned): its model's box, measured once.
function PP.AddVehicle(npc)
	local mins, maxs = npc:GetModelBounds()
	if not mins then return end
	npc.NGLShotMins, npc.NGLShotMaxs = mins, maxs
	PP.Vehicles[npc] = true
end

hook.Add("OnEntityCreated", "NGL.VehicleShots", function(e)
	if e.IsNGLNPC or not isShot(e:GetClass()) then return end
	PP.Shots[e] = true
end)

local function explode(shot, pos, owner)
	local dmg = shot:GetInternalVariable("m_flDamage")
	if not isnumber(dmg) or dmg <= 0 then dmg = 150 end
	local fx = EffectData()
	fx:SetOrigin(pos)
	util.Effect("Explosion", fx, true, true)
	shot:Remove()
	util.BlastDamage(game.GetWorld(), IsValid(owner) and owner or game.GetWorld(), pos, 200, dmg)
end

local function hit(shot, veh, pos)
	local cls = shot:GetClass()
	local owner = shot:GetOwner()
	if BOLT[cls] then
		local dmg = DamageInfo()
		local d = shot:GetInternalVariable("m_flDamage")
		dmg:SetDamage(isnumber(d) and d > 0 and d or 100)
		dmg:SetDamageType(DMG_BULLET)
		dmg:SetAttacker(IsValid(owner) and owner or shot)
		dmg:SetInflictor(shot)
		dmg:SetDamagePosition(pos)
		veh:TakeDamageInfo(dmg)
		shot:EmitSound("Weapon_Crossbow.BoltHitWorld")
		shot:Remove()
	elseif not EXPLODE[cls] and shot:IsScripted() and (shot.Touch or shot.StartTouch) then
		shot:SetPos(pos)
		local fn = shot.StartTouch or shot.Touch
		local ok = pcall(fn, shot, veh)
		if ok and IsValid(shot) and shot.Touch and fn ~= shot.Touch then pcall(shot.Touch, shot, veh) end
		if IsValid(shot) and not shot.NGLTouchedVeh then
			shot.NGLTouchedVeh = true -- its code chose not to go off: leave it be
		end
	else
		explode(shot, pos, owner)
	end
end

hook.Add("Tick", "NGL.VehicleShots", function()
	if not next(PP.Shots) or not next(PP.Vehicles) then return end
	local dt = engine.TickInterval()
	for veh in pairs(PP.Vehicles) do
		if not IsValid(veh) or veh.NGLDying then PP.Vehicles[veh] = nil end
	end
	for shot in pairs(PP.Shots) do
		if not IsValid(shot) then
			PP.Shots[shot] = nil
		elseif not shot.NGLTouchedVeh then
			local pos = shot:GetPos()
			local from = shot.NGLShotLast or pos
			shot.NGLShotLast = pos
			local to = pos + shot:GetVelocity() * dt
			local delta = to - from
			local owner = shot:GetOwner()
			for veh in pairs(PP.Vehicles) do
				if veh ~= owner then
					local mins, maxs = veh.NGLShotMins, veh.NGLShotMaxs
					local c = veh:GetPos()
					local r = maxs:Distance(mins) * 0.5 + delta:Length()
					if pos:DistToSqr(c) < (r + 200) * (r + 200) then
						local hp = util.IntersectRayWithOBB(from, delta, c, veh:GetAngles(), mins, maxs)
						if hp then
							hit(shot, veh, hp)
							break
						end
					end
				end
			end
		end
	end
end)
