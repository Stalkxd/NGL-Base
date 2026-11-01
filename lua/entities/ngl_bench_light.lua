-- Benchmark entity B: a lightweight custom entity.
--
-- The idea we are testing for the NGL foundation:
--   * No per-entity Think at all. One central Tick hook drives every agent.
--   * No engine locomotion or physics. We move with SetPos plus one cheap
--     line trace per tick to stick to the ground.
--   * A simple bounding box for collisions, so bullets and traces still hit.
--   * The server only picks the animation sequence; the client plays it, so the
--     server never has to advance animation frames.

AddCSLuaFile()

ENT.Base = "base_anim"
ENT.Type = "anim"
ENT.PrintName = "NGL Bench (Light)"
ENT.Category = "NGL Base"
ENT.Spawnable = false
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_OPAQUE

local HULL_MINS = Vector(-13, -13, 0)
local HULL_MAXS = Vector(13, 13, 72)

if CLIENT then
	function ENT:Draw()
		-- Play the looping sequence locally; the server never advances the cycle.
		local dur = self:SequenceDuration()
		if dur > 0 then
			self:SetCycle((CurTime() / dur + self:EntIndex() * 0.37) % 1)
		end
		self:DrawModel()
	end

	return
end

function ENT:Initialize()
	local B = NGL.Bench

	self:SetModel(B.Model)
	self:SetMoveType(MOVETYPE_NONE)
	self:SetSolid(SOLID_BBOX)
	self:SetCollisionBounds(HULL_MINS, HULL_MAXS)
	self:SetCollisionGroup(COLLISION_GROUP_NPC)

	self:SetHealth(self.NGLStartHealth or 100)
	self:SetMaxHealth(self:Health())

	self.NGLSeqRun = self:SelectWeightedSequence(ACT_RUN)
	self.NGLSeqIdle = self:SelectWeightedSequence(ACT_IDLE)
	self.NGLSeq = nil
	self.NGLYaw = self:GetAngles().y
	self:SetPoseParameter("move_yaw", 0)

	B.InitAgent(self)
	B.LightAgents[self] = true
end

function ENT:NGLSetSequence(seq)
	if self.NGLSeq ~= seq and seq and seq >= 0 then
		self.NGLSeq = seq
		self:ResetSequence(seq)
		self:SetPlaybackRate(1)
	end
end

function ENT:OnTakeDamage(dmginfo)
	if self:Health() <= 0 then return 0 end

	local hp = self:Health() - dmginfo:GetDamage()
	self:SetHealth(hp)

	if hp <= 0 then
		hook.Run("OnNPCKilled", self, dmginfo:GetAttacker(), dmginfo:GetInflictor())
		NGL.Bench.RemoveAgent(self)
		self:Remove()
	end

	return dmginfo:GetDamage()
end

function ENT:OnRemove()
	NGL.Bench.RemoveAgent(self)
	NGL.Bench.LightAgents[self] = nil
end

----------------------------------------------------------------------------
-- Central driver: one hook for every light agent.
----------------------------------------------------------------------------

local B = NGL.Bench
B.LightAgents = B.LightAgents or {}

local STEP_UP = 18
local STEP_DOWN = 54

local groundTrace = { mask = MASK_NPCSOLID_BRUSHONLY }
local groundResult = {}
groundTrace.output = groundResult

local function moveAgent(ent, goal, dt)
	local pos = ent:GetPos()
	local dx, dy = goal.x - pos.x, goal.y - pos.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1 then return false end

	local step = math.min(B.MoveSpeed * dt, len) / len
	local nx, ny = pos.x + dx * step, pos.y + dy * step

	groundTrace.start = Vector(nx, ny, pos.z + STEP_UP)
	groundTrace.endpos = Vector(nx, ny, pos.z - STEP_DOWN)
	util.TraceLine(groundTrace)

	-- Starting inside a wall or no floor below (ledge): stay put.
	if groundResult.StartSolid or not groundResult.Hit then return false end

	ent:SetPos(groundResult.HitPos)
	return true
end

local function faceTowards(ent, point)
	local pos = ent:GetPos()
	local yaw = math.deg(math.atan2(point.y - pos.y, point.x - pos.x))
	-- Only send a new angle when it changed noticeably (saves network updates).
	if math.abs(math.AngleDifference(yaw, ent.NGLYaw)) > 2 then
		ent.NGLYaw = yaw
		ent:SetAngles(Angle(0, yaw, 0))
	end
end

hook.Add("Tick", "NGL.Bench.LightDriver", function()
	if next(B.LightAgents) == nil then return end

	local now = CurTime()
	local dt = engine.TickInterval()

	for ent in pairs(B.LightAgents) do
		if IsValid(ent) then
			B.ThinkAgent(ent, now)

			local t0 = SysTime()
			local goal = ent.NGLMoveGoal
			local moved = goal and moveAgent(ent, goal, dt)
			ent:NGLSetSequence(moved and ent.NGLSeqRun or ent.NGLSeqIdle)

			local face = ent.NGLFace or goal
			if face then faceTowards(ent, face) end
			B.LuaTime = B.LuaTime + (SysTime() - t0)
		else
			B.LightAgents[ent] = nil
		end
	end
end)
