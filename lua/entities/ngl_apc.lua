-- Combine APC: an NGL NPC like the others (same scheduler, budget and level
-- of detail), driven like a vehicle. A turret machine gun for infantry and
-- rockets for groups, players and other vehicles. Keeps its distance, backs
-- off when enemies get close. A squad leader of its faction nearby (the
-- elite Combine) commands it: rocket barrages on a spot, and it follows the
-- leader when there's nothing to fight. Alone, it decides for itself.
AddCSLuaFile()

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
ENT.EyeHeight = 90              -- turret height: shots and sight start here
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

-- Turret machine gun (the normal weapon, so orders and far-away silent
-- shots work as for every NPC).
ENT.Weapon = {
	Damage = 8,
	Delay = 0.1,
	Spread = 0.03,
	Accuracy = 0.55,
	Sound = "Weapon_AR2.NPC_Single",
	Clip = 60,
	ReloadTime = 3,
}

-- Rockets: entity-free projectiles (sv_projectile.lua).
ENT.Rockets = {
	Damage = 90,
	Radius = 220,
	Speed = 1500,
	Gravity = 0,
	Model = "models/weapons/w_missile_closed.mdl",
	HitSound = "BaseExplosionEffect.Sound",
	Sound = "PropAPC.FireRocket",
	Delay = 4,                  -- seconds between rockets in normal combat
	Barrage = 3,                -- rockets per fire_at order
	BarrageSpread = 200,
}

-- Turret pose parameters, first one the model has.
ENT.TurretPoses = {
	yaw = { "vehicle_weapon_yaw", "weapon_yaw", "aim_yaw" },
	pitch = { "vehicle_weapon_pitch", "weapon_pitch", "aim_pitch" },
}

list.Set("NPC", "ngl_apc", {
	Name = "Combine APC (NGL)",
	Class = "ngl_apc",
	Category = "NGL Base",
})

if CLIENT then return end

local IsValid, CurTime = IsValid, CurTime
local Rand = math.Rand

-- A vehicle has no body animations, gestures or hand signals.
function ENT:NGLSetAct() end
function ENT:NGLGesture() end
function ENT:NGLSignal() return false end

function ENT:OnSpawned()
	local h = self.Hull
	self:SetCollisionBounds(h[1], h[2])
	self.loco:SetAcceleration(250)
	self.loco:SetDeceleration(500)
	self.loco:SetStepHeight(24)
	self.loco:SetMaxYawRate(70)
	self.NGLNextRocket = 0
	self.NGLTurret = {}
	for k, names in pairs(self.TurretPoses) do
		for _, n in ipairs(names) do
			if self:LookupPoseParameter(n) >= 0 then
				self.NGLTurret[k] = n
				break
			end
		end
	end
end

-- Turret follows what it shoots at (an enemy, or a fire_at spot).
function ENT:NGLUpdatePose()
	self.NGLPosed = true
	local t = self.NGLTurret
	if not (t and t.yaw) then return end
	local aim = self.NGLTurretPos
	local e = self.NGLEnemy
	if not aim and IsValid(e) and self.NGLEnemyVisible then aim = e:WorldSpaceCenter() end
	local ay, ap = 0, 0
	if aim then
		local eye = self:GetPos()
		eye.z = eye.z + self.EyeHeight
		local a = (aim - eye):Angle()
		ay, ap = math.AngleDifference(a.y, self:GetAngles().y), math.AngleDifference(a.p, 0)
	end
	if math.abs(ay - (self.NGLAimYaw or 0)) > 2 or math.abs(ap - (self.NGLAimPitch or 0)) > 2 then
		self.NGLAimYaw, self.NGLAimPitch = ay, ap
		self:SetPoseParameter(t.yaw, ay)
		if t.pitch then self:SetPoseParameter(t.pitch, ap) end
	end
end

function ENT:NGLResetPose()
	self.NGLPosed = false
end

function ENT:OnDamaged(dmg)
	if dmg:IsBulletDamage() or dmg:IsDamageType(DMG_CLUB) or dmg:IsDamageType(DMG_SLASH) then
		dmg:ScaleDamage(self.BulletDamageScale)
	end
end

local function fireRocket(self, target)
	local r = self.Rockets
	self:FireProjectile(target, r)
	if self.NGLNear and r.Sound then self:EmitSound(r.Sound) end
end

-- Worth a rocket: players, vehicles, enemies far away, or packed groups.
local function rocketWorthy(self, enemy, dist)
	if enemy:IsPlayer() or enemy.IsVehicleNPC or dist > 1500 then return true end
	local n = 0
	for _, e in ipairs(NGL.FindInRadius(enemy:GetPos(), 250, function(e) return NGL.Core.IsHostile(self, e) end)) do
		n = n + 1
		if n >= 2 then return true end
	end
	return false
end

-- Orders: a fire_at order is a rocket barrage (the other kinds run as for
-- every NPC: hold and move use the machine gun).
function ENT:OnAIThink(dt)
	local o = self.NGLOrder
	if not (o and o.kind == "fire_at" and self.Rockets) then
		self.NGLTurretPos = nil
		return
	end
	local Core = NGL.Core
	local now = CurTime()
	if self.NGLGoal or self.NGLPath then Core.StopMoving(self) end
	self.NGLTurretPos = o.pos
	o.nextShot = o.nextShot or now + 0.8 -- the turret swings round first
	if now >= o.nextShot then
		local r = self.Rockets
		local sp = o.spread or r.BarrageSpread
		fireRocket(self, o.pos + Vector(Rand(-sp, sp), Rand(-sp, sp), 0))
		o.fired = (o.fired or 0) + 1
		o.nextShot = now + 0.7
		if o.fired >= (o.rockets or r.Barrage) then
			self.NGLNextRocket = now + r.Delay
			Core.EndOrder(self, "done")
		end
	end
	return true
end

-- Own fight: keep between MinRange and AttackRange, machine gun always,
-- rockets when worth it. Never strafes.
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
		self:NGLSetMoveMode("run")
		Core.Chase(self, now, pos, tPos, true)
	elseif dist < self.MinRange then
		-- Too close: drive away from it.
		local away = pos - tPos
		away.z = 0
		away:Normalize()
		if not self.NGLGoal or self.NGLGoal:DistToSqr(pos) < 64 * 64 then
			Core.StopMoving(self)
			self:NGLSetMoveMode("run")
			self.NGLGoal = pos + away * 500
		end
	elseif self.NGLGoal or self.NGLPath then
		Core.StopMoving(self)
	end

	if dist < self.AttackRange * 1.2 then
		Core.Shoot(self, now, dt, enemy)
		local r = self.Rockets
		if r and now >= self.NGLNextRocket and dist > 300 and rocketWorthy(self, enemy, dist) then
			self.NGLNextRocket = now + r.Delay
			fireRocket(self, enemy)
		end
	end
	return true
end

-- Nothing to fight: stay behind our commander if we have one.
function ENT:OnIdle()
	local c = self.NGLCommander
	if not (IsValid(c) and not c.NGLDying) then
		self.NGLCommander = nil
		return
	end
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
