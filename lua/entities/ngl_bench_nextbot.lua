-- Benchmark entity A: a standard engine NextBot.
--
-- Uses the stock NextBot locomotion and animation (BodyMoveXY), and moves with
-- loco:Approach directly towards its goal. It does NOT use PathFollower, so no
-- navmesh is needed; real NextBot NPCs that path-find will cost more than this.

AddCSLuaFile()

ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "NGL Bench (NextBot)"
ENT.Category = "NGL Base"
ENT.Spawnable = false
ENT.AdminOnly = true

if CLIENT then return end

function ENT:Initialize()
	local B = NGL.Bench

	self:SetModel(B.Model)
	self:SetHealth(self.NGLStartHealth or 100)
	self:SetMaxHealth(self:Health())

	self.loco:SetDesiredSpeed(B.MoveSpeed)
	self.loco:SetAcceleration(900)
	self.loco:SetDeceleration(900)
	self.loco:SetStepHeight(18)

	self.NGLActivity = nil
	B.InitAgent(self)
end

function ENT:NGLSetActivity(act)
	if self.NGLActivity ~= act then
		self.NGLActivity = act
		self:StartActivity(act)
	end
end

function ENT:RunBehaviour()
	local B = NGL.Bench

	while true do
		B.ThinkAgent(self, CurTime())

		local t0 = SysTime()
		local goal = self.NGLMoveGoal
		if goal then
			self:NGLSetActivity(ACT_RUN)
			self.loco:Approach(goal, 1)
		else
			self:NGLSetActivity(ACT_IDLE)
		end

		local face = self.NGLFace or goal
		if face then
			self.loco:FaceTowards(face)
		end
		B.LuaTime = B.LuaTime + (SysTime() - t0)

		coroutine.yield()
	end
end

function ENT:OnKilled(dmginfo)
	hook.Run("OnNPCKilled", self, dmginfo:GetAttacker(), dmginfo:GetInflictor())
	NGL.Bench.RemoveAgent(self)
	self:Remove()
end

function ENT:OnRemove()
	NGL.Bench.RemoveAgent(self)
end
