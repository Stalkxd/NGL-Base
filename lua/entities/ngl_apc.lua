-- Combine APC: an NGL NPC like the others (same scheduler, budget and level
-- of detail), but it drives like a car: it speeds up and brakes, steers
-- with its front wheels, can't turn on the spot and backs up to get round
-- tight corners or away from enemies. Wheels spin and steer on clients.
-- A turret machine gun fires from the barrel with HL2's tracers, and guided
-- rockets go up out of the launcher and curve down onto the target like
-- HL2's APC missiles. A squad leader of its faction nearby (the elite
-- Combine) commands it: rocket barrages on a spot, and it follows the
-- leader when there's nothing to fight. Alone, it decides for itself.
--
-- It sits on the ground like a car: the body pitches and rolls with the
-- ground under its four wheels, slows down uphill and speeds up a little
-- downhill. With no commander it patrols on its own, and in a fight it
-- keeps driving to new spots round the enemy instead of sitting still.
--
-- Source vehicle models face +Y, so the entity's angles are the model's and
-- the direction it drives is 90 degrees from them (HeadingOffset).
AddCSLuaFile()
DEFINE_BASECLASS("ngl_base")

ENT.Base = "ngl_base"
ENT.PrintName = "Combine APC (NGL)"
ENT.Spawnable = false

ENT.Model = "models/combine_apc.mdl"
ENT.Faction = "combine"
ENT.StartHealth = 1200
ENT.RunSpeed = 320
ENT.WalkSpeed = 160
ENT.SightRange = 5000
ENT.AttackRange = 2500
ENT.MinRange = 500              -- closer than this it backs off
ENT.EyeHeight = 90              -- turret height: sight starts here
ENT.EnemyMemory = 10
ENT.AlertRadius = 2000
ENT.WanderRadius = 0            -- parks instead of strolling
ENT.CrouchChance = 0
ENT.WeaponModel = false

ENT.NavWidth = 80               -- paths avoid spots narrower than 160 units
ENT.DriveLikeVehicle = true
ENT.Commandable = true
ENT.IsVehicleNPC = true
ENT.BulletDamageScale = 0.15    -- bullets, clubs and claws barely scratch it
ENT.Hull = { Vector(-80, -80, 0), Vector(80, 80, 96) }
ENT.WaypointRadius = 120        -- a car can't hit path points exactly
ENT.JumpDown = 0                -- no jumping, rappelling or doors for a car
ENT.JumpGap = false
ENT.OpenDoors = false

-- Driving.
ENT.HeadingOffset = 90          -- drives along the model's +Y
ENT.WheelBase = 140             -- front to rear axle: sets how tight it turns
ENT.TrackWidth = 110            -- left to right wheels: how much it rolls on side slopes
ENT.WheelRadius = 28            -- HL2's APC wheels (from its hitboxes)
ENT.MaxSteer = 35               -- degrees
ENT.Accel = 220                 -- units per second^2
ENT.Brake = 500
ENT.ReverseSpeed = 150
ENT.SlopeSlow = 1.5             -- uphill speed loss per unit of slope (0.3 slope = 45% slower); downhill gains a little
ENT.MaxTilt = 40                -- steepest ground (degrees) the body follows

-- On its own (no squad leader commanding it): drives to a random spot
-- MinDist..Radius from where it spawned, waits Pause seconds, and again.
-- false = park and wait.
ENT.Patrol = { Radius = 3000, MinDist = 800, Pause = { 6, 15 } }
-- In a fight the turret does the aiming: the body doesn't turn to face
-- enemies. It shifts forward or back along the way it points (it never
-- swings round) RepositionDelay seconds after the last shift, sooner when
-- it is getting hit.
ENT.RepositionDelay = { 12, 20 }

-- Turret machine gun (HL2's APC: bursts of 10, 2 seconds apart, AR2 rounds,
-- helicopter tracers and muzzle flash from the "muzzle" attachment).
ENT.Weapon = {
	Damage = 8,
	Delay = 0.075,
	Spread = 0.07,
	Accuracy = 0.55,
	Sound = "Weapon_AR2.Single",
	Tracer = "HelicopterTracer",
	MuzzleEffect = "ChopperMuzzleFlash",
	Clip = 10,
	ReloadTime = 2,
}

-- Rockets: entity-free guided projectiles (sv_projectile.lua) that start
-- like HL2's: launched up out of "cannon_muzzle" at 800 units/s, lit after
-- 0.3 s, then turn onto the target.
ENT.Rockets = {
	Damage = 90,
	Radius = 220,
	Speed = 800,
	Gravity = 0,
	Spread = 0,
	Homing = { Delay = 0.3, Turn = 180, Speed = 1500, Accel = 1000 },
	Trail = true,
	Life = 8,
	Model = "models/weapons/w_missile_launch.mdl",
	HitSound = "BaseExplosionEffect.Sound",
	Sound = "weapons/rpg/rocketfire1.wav",
	Delay = 4,                  -- seconds between rockets in normal combat
	MinRange = 800,
	Barrage = 3,                -- rockets per fire_at order
	BarrageSpread = 200,
}

-- Turret pose parameters, first one the model has.
ENT.TurretPoses = {
	yaw = { "vehicle_weapon_yaw", "weapon_yaw", "aim_yaw" },
	pitch = { "vehicle_weapon_pitch", "weapon_pitch", "aim_pitch" },
}
ENT.TurretTurnSpeed = 180       -- degrees per second

-- Engine (client).
ENT.EngineSounds = { Idle = "vehicles/apc/apc_idle1.wav", Drive = "vehicles/apc/apc_cruise_loop3.wav" }

list.Set("NPC", "ngl_apc", {
	Name = "Combine APC (NGL)",
	Class = "ngl_apc",
	Category = "NGL Base",
})

local AngleDiff, deg, rad, atan2 = math.AngleDifference, math.deg, math.rad, math.atan2
local clamp, NormalizeAngle = math.Clamp, math.NormalizeAngle

-- What the turret aims at, for clients: they turn the gun themselves every
-- frame, so it tracks smoothly instead of in steps.
function ENT:SetupDataTables()
	BaseClass.SetupDataTables(self)
	self:NetworkVar("Entity", 0, "AimEnt")
	self:NetworkVar("Vector", 0, "AimPos")
end

-- Turret angles (pose values, yaw 90 = straight ahead) to aim at `aim` from
-- `from`, in the body's frame so the gun stays on target on slopes. Shared:
-- the server uses it for the muzzle, clients to draw the gun.
function ENT:NGLAimAngles(from, aim)
	local d = aim - from
	local F, R, U = self:GetForward(), self:GetRight(), self:GetUp()
	local x, y, z = d:Dot(F), -d:Dot(R), d:Dot(U)
	return deg(atan2(y, x)), clamp(-deg(atan2(z, math.sqrt(x * x + y * y))), -45, 45)
end

if CLIENT then
	-- Wheels spin with the distance driven, steer with the turn rate and
	-- follow the ground (suspension), all worked out here from how the APC
	-- moves: nothing extra is networked.
	local ENGINE_RANGE = 3000
	local DETAIL_RANGE = 2500   -- suspension and turret are worked out within this
	local WHEELS = { "fl", "fr", "rl", "rr" }

	local wheelTrace = { mask = MASK_PLAYERSOLID_BRUSHONLY }
	local wheelResult = {}
	wheelTrace.output = wheelResult

	function ENT:NGLFindWheelPoses()
		local spin, steer = {}, nil
		for i = 0, self:GetNumPoseParameters() - 1 do
			local name = self:GetPoseParameterName(i)
			local lo, hi = self:GetPoseParameterRange(i)
			if string.find(name, "spin", 1, true) then
				spin[#spin + 1] = { name, lo, hi }
			elseif string.find(name, "steer", 1, true) then
				steer = { name, lo, hi }
			end
		end
		self.NGLWheelSpin, self.NGLWheelSteer = spin, steer
		-- Suspension, as HL2 works it out: height pose 0 is the model's own
		-- wheel position and 1 is fully dropped; measure how far that is.
		-- (Left unset the pose sits at -1: wheels pulled up into the body.)
		local W = {}
		for _, k in ipairs(WHEELS) do
			local pose, att = "vehicle_wheel_" .. k .. "_height", self:LookupAttachment("wheel_" .. k)
			if self:LookupPoseParameter(pose) >= 0 and att and att > 0 then W[#W + 1] = { pose = pose, att = att, cur = 0 } end
		end
		local function measure(v, key)
			for _, w in ipairs(W) do self:SetPoseParameter(w.pose, v) end
			self:InvalidateBoneCache()
			self:SetupBones()
			for _, w in ipairs(W) do
				local a = self:GetAttachment(w.att)
				w[key] = a and self:WorldToLocal(a.Pos) or nil
			end
		end
		measure(1, "low")
		measure(0, "base")
		local ok = {}
		for _, w in ipairs(W) do
			if w.base and w.low and w.base.z - w.low.z > 0.5 then
				w.travel = w.base.z - w.low.z
				ok[#ok + 1] = w
			elseif w.base then
				ok[#ok + 1] = w -- no travel measured: just keep it at 0
			end
		end
		self.NGLSusp = ok
		local gb = self:LookupAttachment("gun_base")
		local a = gb and gb > 0 and self:GetAttachment(gb)
		self.NGLGunBase = a and self:WorldToLocal(a.Pos) or Vector(0, 0, self.EyeHeight)
	end

	-- Each wheel's height pose from a trace down to the ground under it.
	function ENT:NGLSuspension(near)
		local S = self.NGLSusp
		if not S then return end
		if not near then
			if self.NGLSuspFar then return end
			self.NGLSuspFar = true
			for _, w in ipairs(S) do w.cur = 0; self:SetPoseParameter(w.pose, 0) end
			return
		end
		self.NGLSuspFar = nil
		local up = self:GetUp()
		local R = self.WheelRadius
		local k = math.min(FrameTime() * 15, 1)
		for _, w in ipairs(S) do
			local want = 0
			if w.travel then
				local c = self:LocalToWorld(w.base)
				local reach = R + w.travel + 8
				wheelTrace.start = c + up * 24
				wheelTrace.endpos = c - up * reach
				wheelTrace.filter = self
				util.TraceLine(wheelTrace)
				local dist = wheelResult.Hit and (wheelResult.Fraction * (reach + 24) - 24) or reach
				want = clamp((dist - R) / w.travel, -1, 1)
			end
			w.cur = w.cur + (want - w.cur) * k
			self:SetPoseParameter(w.pose, w.cur)
		end
	end

	-- The gun turns towards what the server says it aims at, every frame.
	function ENT:NGLTurretClient()
		local e, p = self:GetAimEnt(), self:GetAimPos()
		local aim = IsValid(e) and e:WorldSpaceCenter() or (p ~= vector_origin and p) or nil
		local ay, ap = 90, 0
		if aim then ay, ap = self:NGLAimAngles(self:LocalToWorld(self.NGLGunBase), aim) end
		local step = self.TurretTurnSpeed * FrameTime()
		local cy, cp = self.NGLCAimYaw or 90, self.NGLCAimPitch or 0
		cy = NormalizeAngle(cy + clamp(AngleDiff(ay, cy), -step, step))
		cp = cp + clamp(ap - cp, -step, step)
		self.NGLCAimYaw, self.NGLCAimPitch = cy, cp
		self:SetPoseParameter("vehicle_weapon_yaw", cy)
		self:SetPoseParameter("vehicle_weapon_pitch", cp)
	end

	function ENT:NGLWheels()
		if not self.NGLWheelSpin then self:NGLFindWheelPoses() end
		local now = CurTime()
		local pos, yaw = self:GetPos(), self:GetAngles().y
		local lastPos, lastYaw, lastT = self.NGLLastPos, self.NGLLastYaw, self.NGLLastT
		self.NGLLastPos, self.NGLLastYaw, self.NGLLastT = pos, yaw, now
		if not lastPos then return end
		local dt = now - lastT
		if dt <= 0 then return end
		local h = rad(yaw + self.HeadingOffset)
		local speed = ((pos.x - lastPos.x) * math.cos(h) + (pos.y - lastPos.y) * math.sin(h)) / dt
		self.NGLSpeed = speed
		self.NGLSpin = ((self.NGLSpin or 0) + deg(speed * dt / self.WheelRadius)) % 360
		for _, p in ipairs(self.NGLWheelSpin) do
			self:SetPoseParameter(p[1], p[2] + (p[3] - p[2]) * self.NGLSpin / 360)
		end
		local st = self.NGLWheelSteer
		if st then
			local want = 0
			if math.abs(speed) > 20 then
				local yawRate = rad(AngleDiff(yaw, lastYaw)) / dt
				want = clamp(deg(math.atan(yawRate * self.WheelBase / speed)) / self.MaxSteer, -1, 1)
			end
			self.NGLSteerF = (self.NGLSteerF or 0) + (want - (self.NGLSteerF or 0)) * math.min(dt * 6, 1)
			-- The model steers right for positive values; our turn rate is
			-- positive turning left.
			local f = (1 - self.NGLSteerF) / 2
			self:SetPoseParameter(st[1], st[2] + (st[3] - st[2]) * f)
		end
		local near = EyePos():DistToSqr(pos) < DETAIL_RANGE * DETAIL_RANGE
		self:NGLSuspension(near)
		self:NGLTurretClient()
		self:InvalidateBoneCache()
	end

	function ENT:Draw()
		self:NGLWheels()
		BaseClass.Draw(self)
	end

	function ENT:Think()
		local snd = self.EngineSounds
		if snd then
			local near = EyePos():DistToSqr(self:GetPos()) < ENGINE_RANGE * ENGINE_RANGE
			if near and not self.NGLEngine then
				self.NGLEngine = {}
				for k, path in pairs(snd) do
					local s = CreateSound(self, path)
					s:SetSoundLevel(80)
					s:PlayEx(0, 100)
					self.NGLEngine[k] = s
				end
			elseif not near and self.NGLEngine then
				for _, s in pairs(self.NGLEngine) do s:Stop() end
				self.NGLEngine = nil
			end
			local E = self.NGLEngine
			if E then
				local f = clamp(math.abs(self.NGLSpeed or 0) / self.RunSpeed, 0, 1)
				if E.Idle then E.Idle:ChangeVolume(0.6 * (1 - f), 0.2) end
				if E.Drive then
					E.Drive:ChangeVolume(0.3 + 0.7 * f, 0.2)
					E.Drive:ChangePitch(80 + 40 * f, 0.2)
				end
			end
		end
		self:SetNextClientThink(CurTime() + 0.1)
		return true
	end

	function ENT:OnRemove()
		for _, s in pairs(self.NGLEngine or {}) do s:Stop() end
		if BaseClass.OnRemove then BaseClass.OnRemove(self) end
	end
	return
end

local IsValid, CurTime = IsValid, CurTime
local Rand = math.Rand

-- A vehicle has no body animations, gestures or hand signals.
function ENT:NGLSetAct() end
function ENT:NGLGesture() end
function ENT:NGLSignal() return false end

function ENT:OnSpawned()
	local h = self.Hull
	self:SetCollisionBounds(h[1], h[2])
	-- Our own driving sets the speed; the locomotion just follows it.
	self.loco:SetAcceleration(2000)
	self.loco:SetDeceleration(2000)
	self.loco:SetStepHeight(24)
	self.NGLNextRocket = 0
	self.NGLSpeed = 0
	self.NGLHeading = self:GetAngles().y + self.HeadingOffset
	self.NGLTurret = {}
	for k, names in pairs(self.TurretPoses) do
		for _, n in ipairs(names) do
			if self:LookupPoseParameter(n) >= 0 then
				self.NGLTurret[k] = n
				break
			end
		end
	end
	local function att(name) local id = self:LookupAttachment(name); return id and id > 0 and id or nil end
	self.NGLAtt = { muzzle = att("muzzle"), base = att("gun_base"), rocket = att("cannon_muzzle") }
	self.NGLAimYaw, self.NGLAimPitch = 90, 0 -- HL2's rest pose: gun forward
	if self.NGLTurret.yaw then self:SetPoseParameter(self.NGLTurret.yaw, 90) end
	-- Wheels at the model's own height (unset they sit at -1, pulled up
	-- into the body) and straight; clients then follow the ground.
	for _, k in ipairs({ "fl", "fr", "rl", "rr" }) do
		local p = "vehicle_wheel_" .. k .. "_height"
		if self:LookupPoseParameter(p) >= 0 then self:SetPoseParameter(p, 0) end
	end
	if self:LookupPoseParameter("vehicle_steer") >= 0 then self:SetPoseParameter("vehicle_steer", 0) end
	-- Metal: bullets throw sparks, not blood.
	if self.SetBloodColor then self:SetBloodColor(BLOOD_COLOR_MECH) end
end

-- Driving ------------------------------------------------------------------

-- Feelers: how far the way ahead is clear from the front bumper, straight
-- on or turned by `yawOff` (walls and props, not NPCs or walkable slopes).
local feelTrace = { mask = MASK_NPCSOLID_BRUSHONLY }
local feelResult = {}
feelTrace.output = feelResult

function ENT:NGLFeel(pos, heading, yawOff, len, fromCenter)
	local h, o = rad(heading), rad(heading + yawOff)
	local front = fromCenter and 0 or (self.Hull[2].x or 80)
	local sx, sy, z = pos.x + math.cos(h) * front, pos.y + math.sin(h) * front, pos.z + 40
	feelTrace.start = Vector(sx, sy, z)
	feelTrace.endpos = Vector(sx + math.cos(o) * len, sy + math.sin(o) * len, z)
	util.TraceLine(feelTrace)
	if not feelResult.Hit or feelResult.HitNormal.z > 0.7 then return len end
	return feelResult.Fraction * len
end

-- Stuck against something: back up with the wheels turned so the nose
-- swings to the freer side, then drive on that way (or, stuck backing up,
-- just drive forward that way). Stuck three times in a short while, give
-- up on where it was going: patrols and fights pick a new spot and the
-- path is worked out again from here.
function ENT:NGLStartDetour(now, pos, heading, wasForward)
	local l = self:NGLFeel(pos, heading, 60, 300, true)
	local r = self:NGLFeel(pos, heading, -60, 300, true)
	local side = (l > r and 1) or (r > l and -1) or (math.random(2) == 1 and 1 or -1)
	self.NGLDetour = { phase = wasForward and 1 or 2, side = side, untilT = now + (wasForward and 1.8 or 1.4) }
	if now - (self.NGLStuckLast or 0) > 20 then self.NGLStuckN = 0 end
	self.NGLStuckLast = now
	self.NGLStuckN = (self.NGLStuckN or 0) + 1
	if self.NGLStuckN >= 3 then
		self.NGLStuckN = 0
		self.NGLPatrolTo, self.NGLReposition, self.NGLBackOff = nil, nil, nil
		self.NGLNextPatrol = now + 2
		NGL.Core.StopMoving(self)
	end
end

-- Called every tick by the base BehaveUpdate with the current goal (or nil).
-- A bicycle model: speed along the heading, the heading turns by
-- speed * tan(steer) / wheelbase. Goals far off to the side and close by
-- are reached by backing up while steering the other way (a three-point
-- turn); goals behind and close (backing away from enemies) by reversing.
-- Feelers steer round walls ahead, and a detour gets it off one it hit.
function ENT:NGLDrive(goal, dt)
	dt = dt or engine.TickInterval()
	local pos = self:GetPos()
	local heading = self.NGLHeading or (self:GetAngles().y + self.HeadingOffset)
	local speed = self.NGLSpeed or 0
	local want, steer = 0, 0
	local now = CurTime()
	local D = self.NGLDetour
	if D and (not goal or now > D.untilT) then
		if goal and D.phase == 1 then
			D.phase, D.untilT = 2, now + 1.4
		else
			D, self.NGLDetour = nil, nil
		end
	end

	if goal and D then
		if D.phase == 1 then
			want, steer = -self.ReverseSpeed * 0.8, -D.side * self.MaxSteer
		else
			want, steer = self.WalkSpeed, D.side * self.MaxSteer
		end
	elseif goal then
		local dx, dy = goal.x - pos.x, goal.y - pos.y
		local dist = math.sqrt(dx * dx + dy * dy)
		local off = AngleDiff(deg(atan2(dy, dx)), heading)
		local top = self.NGLMoveMode == "walk" and self.WalkSpeed or self.RunSpeed
		-- Reverse: goal behind and close, or a corner too tight.
		local back = self.NGLBacking
		if back and (now > back or math.abs(off) < 45) then back = nil end
		if not back and math.abs(off) > 110 and dist < 700 then back = now + 3 end
		self.NGLBacking = back
		if back then
			-- Backing up: steer the other way, so the nose swings to the goal;
			-- with the goal right behind, keep the tail pointed at it.
			steer = clamp(-off, -self.MaxSteer, self.MaxSteer)
			if math.abs(off) > 150 then
				steer = clamp(-AngleDiff(deg(atan2(dy, dx)), heading + 180), -self.MaxSteer, self.MaxSteer)
			end
			want = -math.min(self.ReverseSpeed, 60 + dist)
		else
			steer = clamp(off, -self.MaxSteer, self.MaxSteer)
			want = top * clamp(1 - math.abs(off) / 150, 0.35, 1) -- slow into turns
			want = math.min(want, 60 + dist * 1.2)              -- and towards the end
			-- Something in the way before the goal: turn towards the side
			-- with more room, harder the closer it is, and slow down.
			if now >= (self.NGLNextFeel or 0) then
				self.NGLNextFeel = now + (self.NGLNear and 0.15 or 0.4)
				local look = clamp(150 + math.abs(speed) * 0.8, 150, 450)
				local c = self:NGLFeel(pos, heading, 0, look)
				self.NGLAvoid = nil
				if c < look and c < dist then
					local l = self:NGLFeel(pos, heading, 30, look)
					local r = self:NGLFeel(pos, heading, -30, look)
					if l ~= r or c < look * 0.5 then
						self.NGLAvoid = { side = (l >= r) and 1 or -1, k = 1 - c / look, c = c }
					end
				end
			end
			local A = self.NGLAvoid
			if A then
				steer = clamp(steer + A.side * A.k * self.MaxSteer * 1.5, -self.MaxSteer, self.MaxSteer)
				if A.c < 120 then want = math.min(want, 90) end
			end
		end
	end

	-- Hills: slower going up, a bit faster going down (the slope along the
	-- way we drive, from the ground under the wheels last tick).
	local slope = self.NGLSlope or 0
	if want ~= 0 and slope ~= 0 then
		local s = (want > 0) and slope or -slope
		want = want * clamp(1 - s * (self.SlopeSlow or 1.5), 0.4, 1.15)
	end

	local rate = (want == 0 or (want > 0) ~= (speed > 0)) and self.Brake or self.Accel
	if speed < want then speed = math.min(want, speed + rate * dt)
	elseif speed > want then speed = math.max(want, speed - rate * dt) end

	if speed ~= 0 then
		heading = heading + deg(speed * math.tan(rad(steer)) / self.WheelBase) * dt
		local h = rad(heading)
		local fwd = Vector(math.cos(h), math.sin(h), 0)
		self.loco:SetDesiredSpeed(math.abs(speed))
		self.loco:Approach(pos + fwd * (speed > 0 and 100 or -100), 1)
		-- Not getting anywhere (pushing into a wall): detour round it.
		local moved = self.NGLLastDrivePos and pos:DistToSqr(self.NGLLastDrivePos) or 1e9
		if math.abs(want) > 40 and math.abs(speed) > 60 and moved < 0.25 then
			self.NGLDriveStuckT = (self.NGLDriveStuckT or 0) + dt
			if self.NGLDriveStuckT > 1 then
				self.NGLDriveStuckT = 0
				self:NGLStartDetour(now, pos, heading, speed > 0)
			end
		else
			self.NGLDriveStuckT = 0
		end
	end
	self.NGLLastDrivePos = pos
	self.NGLHeading = heading
	self.NGLSpeed = speed
	self.NGLMoving = math.abs(speed) > 5
	self:SetAngles(self:NGLBodyAngles(heading, dt, now))
end

-- Ground under the wheels ---------------------------------------------------

local groundTrace = { mask = MASK_NPCSOLID_BRUSHONLY }
local groundResult = {}
groundTrace.output = groundResult

-- Normal of the ground under the four wheels (front/rear axle, left/right
-- wheels), or nil when a wheel hangs over an edge or the ground is too
-- steep: then the body keeps the tilt it had.
function ENT:NGLGroundNormal(heading)
	local pos = self:GetPos()
	local h = rad(heading)
	local fx, fy = math.cos(h), math.sin(h)
	local half, track = self.WheelBase * 0.5, (self.TrackWidth or 110) * 0.5
	local function z(f, s)
		local x, y = pos.x + fx * f - fy * s, pos.y + fy * f + fx * s
		groundTrace.start = Vector(x, y, pos.z + 72)
		groundTrace.endpos = Vector(x, y, pos.z - 96)
		util.TraceLine(groundTrace)
		return groundResult.Hit and groundResult.HitPos.z or nil
	end
	local fl, fr, rl, rr = z(half, track), z(half, -track), z(-half, track), z(-half, -track)
	if not (fl and fr and rl and rr) then return nil end
	-- front minus rear, and left minus right; the normal is their cross product
	local ax, ay, az = fx * 2 * half, fy * 2 * half, (fl + fr - rl - rr) * 0.5
	local bx, by, bz = -fy * 2 * track, fx * 2 * track, (fl + rl - fr - rr) * 0.5
	local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)
	if len <= 0 then return nil end
	nx, ny, nz = nx / len, ny / len, nz / len
	if nz < math.cos(rad(self.MaxTilt or 40)) then return nil end
	return Vector(nx, ny, nz)
end

-- Body angles for driving along `heading` on the ground: yaw from the
-- heading, pitch and roll from the ground, eased so bumps don't jitter.
-- Four traces per tick while moving near players, a few a second further
-- away or parked.
function ENT:NGLBodyAngles(heading, dt, now)
	local n = self.NGLNormal or Vector(0, 0, 1)
	if now >= (self.NGLNextGround or 0) then
		self.NGLNextGround = now + ((not self.NGLMoving) and 1 or (self.NGLNear and 0 or 0.3))
		local target = self:NGLGroundNormal(heading)
		if target then
			local k = self.NGLNormal and math.min(dt * 8, 1) or 1
			if not self.NGLMoving then k = 1 end
			n = Vector(n.x + (target.x - n.x) * k, n.y + (target.y - n.y) * k, n.z + (target.z - n.z) * k)
			local len = math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
			n = Vector(n.x / len, n.y / len, n.z / len)
		end
		self.NGLNormal = n
	end
	-- Drive direction laid onto the ground.
	local h = rad(heading)
	local dx, dy = math.cos(h), math.sin(h)
	local dz = -(dx * n.x + dy * n.y) / n.z
	local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
	dx, dy, dz = dx / dl, dy / dl, dz / dl
	self.NGLSlope = dz
	-- The model's forward: the drive direction turned by -HeadingOffset
	-- round the ground normal.
	local o = rad(self.HeadingOffset)
	local cx, cy, cz = dy * n.z - dz * n.y, dz * n.x - dx * n.z, dx * n.y - dy * n.x -- drive x normal
	local co, so = math.cos(o), math.sin(o)
	local X = Vector(dx * co + cx * so, dy * co + cy * so, dz * co + cz * so)
	-- right = forward x up; Source: roll = atan2(-right.z, up.z)
	local rz = X.x * n.y - X.y * n.x
	local pitch = -deg(math.asin(clamp(X.z, -1, 1)))
	local yaw = deg(atan2(X.y, X.x))
	local roll = deg(atan2(-rz, n.z))
	return Angle(pitch, yaw, roll)
end

-- Turret -------------------------------------------------------------------

function ENT:NGLMuzzle()
	local id = self.NGLAtt and self.NGLAtt.muzzle
	local a = id and self:GetAttachment(id)
	if a then return a.Pos, id end
end

-- The gun follows what it shoots at (an enemy, or a fire_at spot): pose
-- angles measured from the gun base, in the model's frame, as HL2 does
-- (yaw 90 = straight ahead).
function ENT:NGLUpdatePose()
	self.NGLPosed = true
	local t = self.NGLTurret
	if not (t and t.yaw) then return end
	local aim = self.NGLTurretPos
	local e = self.NGLEnemy
	if not aim and IsValid(e) and self.NGLEnemyVisible then aim = e:WorldSpaceCenter() end
	local ay, ap = 90, 0
	if aim then
		local base = self.NGLAtt.base and self:GetAttachment(self.NGLAtt.base)
		local from = base and base.Pos or (self:GetPos() + Vector(0, 0, self.EyeHeight))
		ay, ap = self:NGLAimAngles(from, aim)
	end
	local now = CurTime()
	local dt = math.min(now - (self.NGLLastPose or now), 0.5)
	self.NGLLastPose = now
	local step = self.TurretTurnSpeed * math.max(dt, 0.05)
	local ny = NormalizeAngle(self.NGLAimYaw + clamp(AngleDiff(ay, self.NGLAimYaw), -step, step))
	local np = self.NGLAimPitch + clamp(ap - self.NGLAimPitch, -step, step)
	if math.abs(AngleDiff(ny, self.NGLAimYaw)) > 0.5 or math.abs(np - self.NGLAimPitch) > 0.5 then
		self.NGLAimYaw, self.NGLAimPitch = ny, np
		self:SetPoseParameter(t.yaw, ny)
		if t.pitch then self:SetPoseParameter(t.pitch, np) end
	end
end

function ENT:NGLResetPose()
	self.NGLPosed = false
end

function ENT:OnDamaged(dmg)
	self.NGLHurtT = CurTime()
	if dmg:IsBulletDamage() or dmg:IsDamageType(DMG_CLUB) or dmg:IsDamageType(DMG_SLASH) then
		dmg:ScaleDamage(self.BulletDamageScale)
	end
end

-- Rockets ------------------------------------------------------------------

-- HL2's launch directions: up at 45 degrees, fanned from forward to
-- backward, one after the other.
local SIDES = { 0.966, 0.866, 0.5, -0.5, -0.866, -0.966 }

function ENT:NGLFireRocket(target, dst)
	local r = self.Rockets
	local id = self.NGLAtt and self.NGLAtt.rocket
	local a = id and self:GetAttachment(id)
	local src = a and a.Pos or (self:GetPos() + Vector(0, 0, self.EyeHeight + 20))
	self.NGLRocketSide = (self.NGLRocketSide or 0) % #SIDES + 1
	local side = SIDES[self.NGLRocketSide]
	local h = rad(self:GetAngles().y + self.HeadingOffset)
	local dir = Vector(math.cos(h) * side, math.sin(h) * side, 1)
	dst = dst or target:WorldSpaceCenter()
	NGL.Proj.Fire(self, r, src, dst, self.NGLNear, { dir = dir, target = target })
	if self.NGLNear and r.Sound then self:EmitSound(r.Sound, 90) end
end

-- Worth a rocket: players, vehicles, enemies far away, or packed groups.
local function rocketWorthy(self, enemy, dist)
	if enemy:IsPlayer() or enemy.IsVehicleNPC or dist > 1500 then return true end
	local n = 0
	for _ in ipairs(NGL.FindInRadius(enemy:GetPos(), 250, function(e) return NGL.Core.IsHostile(self, e) end)) do
		n = n + 1
		if n >= 2 then return true end
	end
	return false
end

-- Orders: a fire_at order is a rocket barrage (the other kinds run as for
-- every NPC: hold and move use the machine gun).
-- Tell clients what the gun aims at (only when it changes).
function ENT:NGLNetAim()
	local e = self.NGLEnemy
	if not (IsValid(e) and self.NGLEnemyVisible) or self.NGLTurretPos then e = NULL end
	if self:GetAimEnt() ~= e then self:SetAimEnt(e) end
	local p = self.NGLTurretPos or vector_origin
	if self:GetAimPos() ~= p then self:SetAimPos(p) end
end

function ENT:OnAIThink(dt)
	local o = self.NGLOrder
	if not (o and o.kind == "fire_at" and self.Rockets) then
		self.NGLTurretPos = nil
		self:NGLNetAim()
		return
	end
	local Core = NGL.Core
	local now = CurTime()
	if self.NGLGoal or self.NGLPath then Core.StopMoving(self) end
	self.NGLTurretPos = o.pos
	self:NGLNetAim()
	o.nextShot = o.nextShot or now + 0.8 -- the turret swings round first
	if now >= o.nextShot then
		local r = self.Rockets
		local sp = o.spread or r.BarrageSpread
		self:NGLFireRocket(nil, o.pos + Vector(Rand(-sp, sp), Rand(-sp, sp), 0))
		o.fired = (o.fired or 0) + 1
		o.nextShot = now + 0.7
		if o.fired >= (o.rockets or r.Barrage) then
			self.NGLNextRocket = now + r.Delay
			Core.EndOrder(self, "done")
		end
	end
	return true
end

-- Own fight: keep between MinRange and AttackRange (backing away when too
-- close), machine gun always, rockets when worth it. Never strafes.
function ENT:OnCombat(enemy, dist, visible)
	local Core = NGL.Core
	local now = CurTime()
	local dt = math.min(now - (self.NGLLastCombat or now), 1.5)
	self.NGLLastCombat = now
	self.NGLFace = nil
	local pos = self:GetPos()

	if not visible then
		local last = self.NGLLastSeenPos or enemy:GetPos()
		if pos:DistToSqr(last) < 250 * 250 then
			Core.SetEnemy(self, nil)
			return true
		end
		self:NGLSetMoveMode("run")
		Core.Chase(self, now, pos, last, false)
		self.NGLFireAccum = 0
		return true
	end

	local tPos = enemy:GetPos()
	if dist > self.AttackRange then
		self.NGLReposition, self.NGLBackOff = nil, nil
		self:NGLSetMoveMode("run")
		Core.Chase(self, now, pos, tPos, true)
	elseif dist < self.MinRange then
		-- Too close: get away along the way the body points, reversing if
		-- the enemy is in front and driving on if it is behind, without
		-- turning round.
		self.NGLReposition = nil
		if not self.NGLBackOff or not self.NGLGoal or self.NGLGoal:DistToSqr(pos) < 96 * 96 then
			local h = rad(self.NGLHeading or (self:GetAngles().y + self.HeadingOffset))
			local fx, fy = math.cos(h), math.sin(h)
			local ahead = (tPos.x - pos.x) * fx + (tPos.y - pos.y) * fy > 0
			local s = ahead and -1 or 1
			local goal = self:NGLDriveSpot(Vector(pos.x + fx * 500 * s, pos.y + fy * 500 * s, pos.z))
				or self:NGLDriveSpot(Vector(pos.x - fx * 500 * s, pos.y - fy * 500 * s, pos.z))
				or Vector(pos.x + fx * 500 * s, pos.y + fy * 500 * s, pos.z) -- off the grid: straight back anyway
			Core.StopMoving(self)
			self:NGLSetMoveMode("run")
			self.NGLGoal = goal
			self.NGLBackOff = true
		end
	else
		-- In range: now and then shift to another spot along the body,
		-- the turret firing on the move, so it is never a sitting target.
		if self.NGLBackOff then
			self.NGLBackOff = nil
			Core.StopMoving(self)
		end
		local R = self.NGLReposition
		if R and (pos:DistToSqr(R) < 160 * 160 or now > (self.NGLRepositionUntil or 0)) then
			R = nil
			self.NGLReposition = nil
			Core.StopMoving(self)
		end
		if R then
			self:NGLSetMoveMode("walk")
			Core.Chase(self, now, pos, R, false)
		elseif now >= (self.NGLNextReposition or 0) or (now - (self.NGLHurtT or -99) < 2 and now >= (self.NGLNextReposition or 0) - 8) then
			local d = self.RepositionDelay or { 12, 20 }
			self.NGLNextReposition = now + Rand(d[1], d[2])
			local spot = self:NGLCombatSpot(pos, tPos, dist)
			if spot then
				self.NGLReposition = spot
				self.NGLRepositionUntil = now + 10
			end
		elseif self.NGLGoal or self.NGLPath then
			Core.StopMoving(self)
		end
	end

	if dist < self.AttackRange * 1.2 then
		Core.Shoot(self, now, dt, enemy)
		local r = self.Rockets
		if r and now >= self.NGLNextRocket and dist > (r.MinRange or 300) and rocketWorthy(self, enemy, dist) then
			self.NGLNextRocket = now + r.Delay
			self:NGLFireRocket(enemy)
		end
	end
	return true
end

-- A grid spot wide enough for the APC, or nil (any spot without a grid).
function ENT:NGLDriveSpot(p)
	local spot, node = NGL.Core.GridSpot(p)
	if not spot then return nil end
	local w = self.NavWidth
	if node and w and w > 24 and not NGL.Nav.WideOk(node, math.ceil(w / 8) * 8) then return nil end
	return spot
end

-- Another spot 300..600 units forward or back along the way the body
-- points (reached without turning round), still between MinRange and
-- AttackRange from the enemy.
function ENT:NGLCombatSpot(pos, tPos, dist)
	local h = rad(self.NGLHeading or (self:GetAngles().y + self.HeadingOffset))
	local fx, fy = math.cos(h), math.sin(h)
	local first = math.random(2) == 1 and 1 or -1
	for i = 1, 4 do
		local s = (i % 2 == 1) and first or -first
		local d = Rand(300, 600) * s
		local p = Vector(pos.x + fx * d, pos.y + fy * d, pos.z)
		local e = math.sqrt((p.x - tPos.x) ^ 2 + (p.y - tPos.y) ^ 2)
		if e > self.MinRange + 100 and e < self.AttackRange * 0.95 then
			local spot = self:NGLDriveSpot(p)
			if spot then return spot end
		end
	end
end

-- On its own: drive somewhere else round where it spawned, wait, repeat.
function ENT:NGLPatrol(now, pos)
	local P = self.Patrol
	if not P then return end -- parks
	local to = self.NGLPatrolTo
	if to then
		if pos:DistToSqr(to) < 250 * 250 or now > (self.NGLPatrolUntil or 0) then
			self.NGLPatrolTo = nil
			self:StopMoving()
			local w = P.Pause or { 6, 15 }
			self.NGLNextPatrol = now + Rand(w[1], w[2])
		else
			self:MoveTo(to, false)
		end
		return true
	end
	if now < (self.NGLNextPatrol or 0) then return true end
	self.NGLNextPatrol = now + 3 -- nowhere to go: try again soon
	local home = self.NGLPatrolHome or pos
	self.NGLPatrolHome = home
	local minD, maxD = P.MinDist or 800, P.Radius or 3000
	for _ = 1, 6 do
		local a = Rand(0, 2 * math.pi)
		local d = Rand(minD, maxD)
		local spot = self:NGLDriveSpot(Vector(home.x + math.cos(a) * d, home.y + math.sin(a) * d, pos.z))
		if spot and pos:DistToSqr(spot) > minD * minD then
			self.NGLPatrolTo = spot
			self.NGLPatrolUntil = now + 90
			self:MoveTo(spot, false)
			return true
		end
	end
	return true
end

-- Nothing to fight: stay behind our commander if we have one, otherwise
-- patrol on our own.
function ENT:OnIdle()
	local c = self.NGLCommander
	if not (IsValid(c) and not c.NGLDying) then
		self.NGLCommander = nil
		return self:NGLPatrol(CurTime(), self:GetPos())
	end
	self.NGLPatrolTo = nil
	local pos = self:GetPos()
	local behind = c:GetPos() - c:GetForward() * 400
	local dSqr = pos:DistToSqr(behind)
	if dSqr > 350 * 350 then
		self:MoveTo(behind, dSqr > 1200 * 1200)
	elseif self:IsMoving() then
		self:StopMoving()
	end
	return true
end

-- Blows up and leaves a burning wreck for a while.
local cvWreck = CreateConVar("ngl_apc_wreck_time", "30", FCVAR_ARCHIVE, "Seconds an NGL APC wreck stays.", 0, 600)
function ENT:OnKilled(dmginfo)
	if self.NGLDying then return end
	self.NGLDying = true
	local attacker = dmginfo:GetAttacker()
	hook.Run("OnNPCKilled", self, attacker, dmginfo:GetInflictor())
	self:OnDeath(dmginfo)
	NGL.Core.Remove(self)

	local center = self:WorldSpaceCenter()
	local ed = EffectData()
	ed:SetOrigin(center)
	util.Effect("Explosion", ed)
	util.BlastDamage(self, IsValid(attacker) and attacker or self, center, 300, 100)

	local t = cvWreck:GetFloat()
	if t > 0 then
		local wreck = ents.Create("prop_physics")
		if IsValid(wreck) then
			wreck:SetModel(self:GetModel())
			wreck:SetPos(self:GetPos())
			wreck:SetAngles(self:GetAngles())
			wreck:SetColor(Color(45, 45, 45))
			wreck:Spawn()
			wreck:Ignite(math.min(t, 15))
			SafeRemoveEntityDelayed(wreck, t)
		end
	end
	self:Remove()
end
