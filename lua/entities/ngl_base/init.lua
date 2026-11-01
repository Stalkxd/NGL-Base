AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

local cvRagdolls = CreateConVar("ngl_ragdolls", "1", FCVAR_ARCHIVE,
	"Death ragdolls for NGL NPCs: 0 = none, 1 = client-side (cheap, default), 2 = server-side (physics on the server).", 0, 2)

local NEAR_GOAL_SQR = 32 * 32
local WAYPOINT_SQR = 40 * 40

-- Empty default hooks.
function ENT:OnSpawned() end
function ENT:OnSeeEnemy(enemy) end
function ENT:OnLoseEnemy(oldEnemy) end
function ENT:OnDamaged(dmginfo) end
function ENT:OnDeath(dmginfo) end
function ENT:OnAIThink(interval) end

function ENT:Initialize()
	self:SetModel(self.Model)

	local hp = self.NGLStartHealth or self.StartHealth
	self:SetHealth(hp)
	self:SetMaxHealth(hp)

	self.loco:SetDesiredSpeed(self.RunSpeed)
	self.loco:SetAcceleration(900)
	self.loco:SetDeceleration(900)
	self.loco:SetStepHeight(18)

	-- Spawned by the benchmark harness: put each team in its own faction and
	-- leave players alone.
	if self.NGLTeam then
		self.Faction = "bench_" .. self.NGLTeam
		self.NGLIgnorePlayers = true
	end

	self.NGLGoal = nil      -- where to move (set by the AI think)
	self.NGLFace = nil      -- what to look at
	self.NGLEnemy = nil
	self.NGLAct = nil

	NGL.Core.Add(self)
	self:OnSpawned()
end

function ENT:NGLSetAct(act)
	if self.NGLAct ~= act then
		self.NGLAct = act
		self:StartActivity(act)
	end
end

-- The stock NextBot runs RunBehaviour as a coroutine every tick. We skip that
-- entirely: decisions happen in the central scheduler at a lower rate, and the
-- per-tick part below only steers towards the goal it picked.
function ENT:BehaveStart() end
function ENT:RunBehaviour() end

function ENT:BehaveUpdate(interval)
	if self.NGLDying then return end
	local t0 = SysTime()

	local pos = self:GetPos()

	-- Following a nav path: advance waypoints here, every tick, so NPCs that
	-- think rarely (far from players) don't stop at each corner.
	local goal
	local path = self.NGLPath
	if path then
		local idx = self.NGLPathIdx
		local wp = path[idx]
		if wp then
			local dx, dy = wp.x - pos.x, wp.y - pos.y
			if dx * dx + dy * dy < WAYPOINT_SQR then
				idx = idx + 1
				self.NGLPathIdx = idx
				wp = path[idx]
			end
		end
		if wp then
			goal = wp
		else
			self.NGLPath = nil
		end
	end

	if not goal then
		goal = self.NGLGoal
		if goal and pos:DistToSqr(goal) < NEAR_GOAL_SQR then
			goal = nil
			self.NGLGoal = nil
		end
	end

	if goal then
		self.loco:Approach(goal, 1)
		self:NGLSetAct(self.Anims.Run)
	else
		self:NGLSetAct(self.Anims.Idle)
	end

	local face = self.NGLFace or goal
	if face then
		self.loco:FaceTowards(face)
	end

	local B = NGL.Bench
	if B then B.LuaTime = B.LuaTime + (SysTime() - t0) end
end

function ENT:OnInjured(dmginfo)
	-- Fight back against whoever hurt us, if we're allowed to.
	local attacker = dmginfo:GetAttacker()
	if not IsValid(self.NGLEnemy) and IsValid(attacker) and NGL.Core.IsHostile(self, attacker) then
		NGL.Core.SetEnemy(self, attacker)
	end
end

function ENT:OnKilled(dmginfo)
	if self.NGLDying then return end
	self.NGLDying = true

	hook.Run("OnNPCKilled", self, dmginfo:GetAttacker(), dmginfo:GetInflictor())
	self:OnDeath(dmginfo)
	NGL.Core.Remove(self)

	local mode = cvRagdolls:GetInt()
	if mode == 2 then
		self:BecomeRagdoll(dmginfo)
	elseif mode == 1 then
		-- The client turns the model into a ragdoll (see cl_init.lua); the
		-- server only keeps the entity around long enough for that to arrive.
		self:SetNGLDead(true)
		self:SetSolid(SOLID_NONE)
		SafeRemoveEntityDelayed(self, 0.5)
	else
		self:Remove()
	end
end

function ENT:OnRemove()
	NGL.Core.Remove(self)
end
