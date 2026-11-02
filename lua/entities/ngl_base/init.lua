AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

local cvRagdolls = CreateConVar("ngl_ragdolls", "1", FCVAR_ARCHIVE,
	"Death ragdolls for NGL NPCs: 0 = none, 1 = client-side (cheap, default), 2 = server-side (physics on the server).", 0, 2)

local NEAR_GOAL_SQR = 32 * 32
local WAYPOINT_SQR = 40 * 40

local BASE_ANIMS = ENT.Anims
local ANIM_FALLBACK = { IdleAim = "Idle", Walk = "Run", WalkAim = "Walk", RunAim = "Run" }
local resolvedAnims = {} -- [class .. model] = { Idle = act, ... }, shared by NPCs of a kind
local resolvedPoses = {} -- [model] = { aim = bool, move = bool }

-- Empty default hooks.
function ENT:OnSpawned() end
function ENT:OnSeeEnemy(enemy) end
function ENT:OnLoseEnemy(oldEnemy) end
function ENT:OnDamaged(dmginfo) end
function ENT:OnDeath(dmginfo) end
function ENT:OnAIThink(interval) end
function ENT:OnAlerted(ally, pos) end
function ENT:OnReload() end

-- Picks, once per class and model, the first activity of each Anims entry
-- that the model actually has.
function ENT:NGLResolveAnims()
	local key = self:GetClass() .. self:GetModel()
	local r = resolvedAnims[key]
	if not r then
		r = {}
		local own = self.Anims or BASE_ANIMS
		for name, def in pairs(BASE_ANIMS) do
			local list = own[name] or def
			if type(list) == "number" then list = { list } end
			for i = 1, table.maxn(list) do
				local act = list[i]
				if act and self:SelectWeightedSequence(act) >= 0 then
					r[name] = act
					break
				end
			end
		end
		r.Idle = r.Idle or ACT_IDLE
		r.Run = r.Run or ACT_RUN
		for _, name in ipairs({ "IdleAim", "Walk", "WalkAim", "RunAim" }) do
			r[name] = r[name] or r[ANIM_FALLBACK[name]]
		end
		resolvedAnims[key] = r
	end
	self.NGLActs = r

	local model = self:GetModel()
	local p = resolvedPoses[model]
	if not p then
		p = {
			aim = self:LookupPoseParameter("aim_yaw") >= 0 and self:LookupPoseParameter("aim_pitch") >= 0,
			move = self:LookupPoseParameter("move_yaw") >= 0,
		}
		resolvedPoses[model] = p
	end
	self.NGLPoses = p
end

-- Plays a gesture (Fire, Reload, Flinch) over the body. Only NPCs near a
-- player bother: nobody would see it, and each one is networked.
function ENT:NGLGesture(name)
	if not self.NGLNear then return end
	local act = self.NGLActs[name]
	if act then self:RestartGesture(act) end
end

-- Aim and strafe pose, and run speed matched to the animation. Called by the
-- scheduler right after each think, for NPCs near a player only; pose
-- parameters are interpolated on the client, so 10 updates a second look smooth.
local AngleDiff, deg, atan2 = math.AngleDifference, math.deg, math.atan2
function ENT:NGLUpdatePose()
	local p = self.NGLPoses
	local yaw = self:GetAngles().y

	if p.aim then
		local ay, ap = 0, 0
		local enemy = self.NGLEnemy
		if enemy and self.NGLEnemyVisible and IsValid(enemy) then
			local eye = self:GetPos()
			eye.z = eye.z + self.EyeHeight
			local a = (enemy:WorldSpaceCenter() - eye):Angle()
			ay, ap = AngleDiff(a.y, yaw), AngleDiff(a.p, 0)
		end
		if math.abs(ay - (self.NGLAimYaw or 0)) > 2 or math.abs(ap - (self.NGLAimPitch or 0)) > 2 then
			self.NGLAimYaw, self.NGLAimPitch = ay, ap
			self:SetPoseParameter("aim_yaw", ay)
			self:SetPoseParameter("aim_pitch", ap)
		end
	end

	local v = self.loco:GetVelocity()
	local speedSqr = v.x * v.x + v.y * v.y
	if p.move then
		local my = 0
		if self.NGLMoving and speedSqr > 400 then my = AngleDiff(deg(atan2(v.y, v.x)), yaw) end
		if math.abs(my - (self.NGLMoveYaw or 0)) > 5 then
			self.NGLMoveYaw = my
			self:SetPoseParameter("move_yaw", my)
		end
	end

	-- Feet match the ground: play the walk/run cycle at the speed we move.
	if self.NGLMoving then
		local gs = self:GetSequenceGroundSpeed(self:GetSequence())
		if gs > 1 then
			local rate = math.Clamp(math.sqrt(speedSqr) / gs, 0.5, 2)
			if math.abs(rate - self:GetPlaybackRate()) > 0.05 then self:SetPlaybackRate(rate) end
		end
	elseif self:GetPlaybackRate() ~= 1 then
		self:SetPlaybackRate(1)
	end
end

function ENT:NGLSetMoveMode(mode)
	if self.NGLMoveMode ~= mode then
		self.NGLMoveMode = mode
		self.loco:SetDesiredSpeed(mode == "walk" and self.WalkSpeed or self.RunSpeed)
	end
end

function ENT:Initialize()
	local model = self.Model
	if type(model) == "table" then model = model[math.random(#model)] end
	self:SetModel(model)
	self:NGLResolveAnims()

	local hp = self.NGLStartHealth or self.StartHealth
	self:SetHealth(hp)
	self:SetMaxHealth(hp)

	self:NGLSetMoveMode("walk")
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
	self.NGLHome = self:GetPos() -- wander around here
	self.NGLClip = self.Weapon and self.Weapon.Clip or 0

	NGL.Core.Add(self)
	self:OnSpawned()
end

function ENT:NGLSetAct(act)
	if self.NGLAct ~= act then
		self.NGLAct = act
		self:StartActivity(act)
	end
end

-- Engine calls this every tick. Same cost as the stock NextBot version, but
-- it handles every movement activity (the stock one only knows ACT_WALK and
-- ACT_RUN). Far from players the cheaper FrameAdvance is enough.
function ENT:BodyUpdate()
	if self.NGLMoving and self.NGLNear then
		self:BodyMoveXY() -- also advances the frame
	else
		self:FrameAdvance()
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

	local A = self.NGLActs
	local fighting = self.NGLEnemy ~= nil
	if goal then
		self.loco:Approach(goal, 1)
		self.NGLMoving = true
		local aim = fighting and self.NGLFace ~= nil
		if self.NGLMoveMode == "walk" then
			self:NGLSetAct(aim and A.WalkAim or A.Walk)
		else
			self:NGLSetAct(aim and A.RunAim or A.Run)
		end
	else
		self.NGLMoving = false
		self:NGLSetAct(fighting and A.IdleAim or A.Idle)
	end

	local face = self.NGLFace or goal
	if face then
		self.loco:FaceTowards(face)
	end

	local B = NGL.Bench
	if B then B.LuaTime = B.LuaTime + (SysTime() - t0) end
end

function ENT:OnInjured(dmginfo)
	local now = CurTime()
	if now >= (self.NGLNextFlinch or 0) then
		self.NGLNextFlinch = now + 1
		self:NGLGesture("Flinch")
	end

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
