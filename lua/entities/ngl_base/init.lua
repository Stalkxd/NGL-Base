AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

local cvRagdolls = CreateConVar("ngl_ragdolls", "1", FCVAR_ARCHIVE,
	"Death ragdolls for NGL NPCs: 0 = none, 1 = client-side (cheap, default), 2 = server-side (physics on the server).", 0, 2)

local NEAR_GOAL_SQR = 32 * 32
local WAYPOINT_SQR = 40 * 40
local TIGHT_SQR = 16 * 16 -- waypoints in narrow places (doorways): get this close before turning
local EDGE_MOVE = 24      -- walked this far: look for a drop ahead again
local EDGE_LOOK = 40      -- how far ahead
local EDGE_DROP = 36      -- deeper than this (and no path jumping it) is a drop
local edgeTrace = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }

local BASE_ANIMS = ENT.Anims
local ANIM_FALLBACK = { IdleAim = "Idle", Walk = "Run", WalkAim = "Walk", RunAim = "Run", CrouchAim = "CrouchIdle", CrouchIdle = "CrouchAim" }
local resolvedAnims = {} -- [class .. model] = { Idle = act, ... }, shared by NPCs of a kind
local resolvedPoses = {} -- [model] = { aim = bool, move = bool }
local resolvedSounds = {} -- [class .. model] = { Pain = { ... }, ... }
local Core -- NGL.Core, set on first use (entities load after the autorun files)

-- Empty default hooks.
function ENT:OnSpawned() end
function ENT:OnSeeEnemy(enemy) end
function ENT:OnLoseEnemy(oldEnemy) end
function ENT:OnDamaged(dmginfo) end
function ENT:OnDeath(dmginfo) end
function ENT:OnAIThink(interval) end
function ENT:OnAlerted(ally, pos) end
function ENT:OnReload() end
function ENT:OnIdle() end
function ENT:OnCombat(enemy, dist, visible) end
function ENT:OnAttack(enemy, kind) end
function ENT:OnMeleeHit(target, hit) end
function ENT:OnLeapHit(target, hit) end
function ENT:OnOrder(order) end
function ENT:OnOrderDone(order, reason) end

----------------------------------------------------------------------------
-- Sounds
----------------------------------------------------------------------------

-- Sounds plus the SoundsByModel entries whose key is part of our model path,
-- every entry turned into a list. Once per class and model.
function ENT:NGLResolveSounds()
	local model = self:GetModel()
	local key = self:GetClass() .. model
	local r = resolvedSounds[key]
	if not r then
		r = {}
		local function add(t)
			for kind, v in pairs(t) do
				r[kind] = (type(v) == "table") and v or { v }
			end
		end
		add(self.Sounds or {})
		local lower = string.lower(model)
		for pattern, t in pairs(self.SoundsByModel or {}) do
			if string.find(lower, string.lower(pattern), 1, true) then add(t) end
		end
		resolvedSounds[key] = r
	end
	self.NGLSounds = r
end

-- Plays one of the sounds of a kind (Alert, Idle, Pain, Death, Reload,
-- Attack, Lost). Only when a player is within ngl_ai_visual_range, and voice
-- lines don't overlap (VoiceCooldown).
-- priority: say it even right after another line (squad commands).
-- With ENT.Radio, voice lines (not Pain or Death) come with a radio click
-- before and after, like the HL2 Combine.
local NO_RADIO = { Pain = true, Death = true }
function ENT:NGLSound(kind, priority)
	if not self.NGLNear then return end
	local list = self.NGLSounds[kind]
	if not list then return end
	local snd = list[math.random(#list)]
	if kind == "Death" then
		-- The entity is about to go away; play it at the spot instead.
		local pos = self:GetPos()
		pos.z = pos.z + self.EyeHeight
		sound.Play(snd, pos, self.SoundLevel, self.SoundPitch)
		return
	end
	local now = CurTime()
	if not priority and now < (self.NGLNextVoice or 0) then return end
	local radio = self.Radio
	local len = SoundDuration(snd) or 0
	self.NGLNextVoice = now + math.max(self.VoiceCooldown, len)
	if radio and not NO_RADIO[kind] then
		if radio.On then self:EmitSound(radio.On[math.random(#radio.On)], self.SoundLevel, 100, 1, CHAN_ITEM) end
		if radio.Off and len > 0 then
			local off = radio.Off[math.random(#radio.Off)]
			timer.Simple(len, function()
				if IsValid(self) and not self.NGLDying then self:EmitSound(off, self.SoundLevel, 100, 1, CHAN_ITEM) end
			end)
		end
	end
	self:EmitSound(snd, self.SoundLevel, self.SoundPitch, 1, CHAN_VOICE)
end

-- Picks, once per class and model, the first activity of each Anims entry
-- that the model actually has.
function ENT:NGLResolveAnims()
	local key = self:GetClass() .. self:GetModel()
	local r = resolvedAnims[key]
	if not r then
		r = {}
		local own = self.Anims or BASE_ANIMS
		for name, def in pairs(BASE_ANIMS) do
			local list = own[name]
			if list == nil then list = def end
			if list == false then list = {} end -- explicitly disabled
			if type(list) == "number" then list = { list } end
			for i = 1, table.maxn(list) do
				local act = list[i]
				local ok
				if isstring(act) then
					ok = self.LookupSequence ~= nil and self:LookupSequence(act) >= 0
				else
					ok = act and self:SelectWeightedSequence(act) >= 0
				end
				if ok then
					r[name] = act
					break
				end
			end
		end
		r.Idle = r.Idle or ACT_IDLE
		r.Run = r.Run or ACT_RUN
		for _, name in ipairs({ "IdleAim", "Walk", "WalkAim", "RunAim", "CrouchAim", "CrouchIdle" }) do
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

-- Plays a gesture (Fire, Reload, Flinch) over the body. Only NPCs within
-- ngl_anim_detail_range of a player bother: each gesture is networked and
-- makes every client blend an extra animation layer.
function ENT:NGLGesture(name)
	if not self.NGLDetail then return end
	local act = self.NGLActs[name]
	if act then self:RestartGesture(act) end
end

-- Hand signal (Anims.Signal<kind>): a gesture over whatever the body does,
-- or, for models with only the full-body signal, that animation while
-- standing still. Near players only, like every other gesture.
local GESTURE_SIGNALS = {}
for _, a in pairs({ ACT_GESTURE_SIGNAL_HALT, ACT_GESTURE_SIGNAL_FORWARD, ACT_GESTURE_SIGNAL_ADVANCE,
	ACT_GESTURE_SIGNAL_GROUP, ACT_GESTURE_SIGNAL_LEFT, ACT_GESTURE_SIGNAL_RIGHT, ACT_GESTURE_SIGNAL_TAKECOVER }) do
	GESTURE_SIGNALS[a] = true
end
-- Stock HL2 models only have the full-body signals (ACT_SIGNAL_*): the NPC
-- stops for the second or so the signal takes, like HL2 Combine do.
function ENT:NGLSignal(kind)
	if not self.NGLNear then return false end
	local act = self.NGLActs["Signal" .. kind]
	if not act then return false end
	if GESTURE_SIGNALS[act] then
		if not self.NGLDetail then return false end
		self:RestartGesture(act)
		return true
	end
	if self.NGLAnimUntil or self.NGLMeleeTarget then return false end
	self.NGLCrouch = false
	return self:PlayAnim(act, true) ~= false
end

-- Aim and strafe pose, and run speed matched to the animation. Called by the
-- scheduler right after each think, for NPCs within ngl_anim_detail_range of
-- a player only; pose parameters are interpolated on the client, so 10
-- updates a second look smooth.
local AngleDiff, deg, atan2 = math.AngleDifference, math.deg, math.atan2
function ENT:NGLUpdatePose()
	self.NGLPosed = true
	local p = self.NGLPoses
	local yaw = self:GetAngles().y

	if p.aim then
		local ay, ap = 0, 0
		local enemy = self.NGLEnemy
		if enemy and self.NGLEnemyVisible and IsValid(enemy) then
			local eye = self:GetPos()
			eye.z = eye.z + (self.NGLCrouch and self.CrouchEyeHeight or self.EyeHeight)
			local a = (enemy:WorldSpaceCenter() - eye):Angle()
			ay, ap = AngleDiff(a.y, yaw), AngleDiff(a.p, 0)
		end
		if math.abs(ay - (self.NGLAimYaw or 0)) > 2 or math.abs(ap - (self.NGLAimPitch or 0)) > 2 then
			self.NGLAimYaw, self.NGLAimPitch = ay, ap
			self:SetPoseParameter("aim_yaw", ay)
			self:SetPoseParameter("aim_pitch", ap)
		end
	end

	-- Feet match the ground. While moving, BodyMoveXY (BodyUpdate) sets the
	-- playback rate every tick; setting it here too made the cycle stutter.
	if self.NGLAnimUntil or self.NGLMoving then
		-- PlayAnim / BodyMoveXY own the playback rate
	elseif self:GetPlaybackRate() ~= 1 then
		self:SetPlaybackRate(1)
	end
end

-- Left full-detail range: put the poses back to neutral once, then leave
-- them alone (no more pose updates to network).
function ENT:NGLResetPose()
	self.NGLPosed = false
	local p = self.NGLPoses
	if p.aim and ((self.NGLAimYaw or 0) ~= 0 or (self.NGLAimPitch or 0) ~= 0) then
		self.NGLAimYaw, self.NGLAimPitch = 0, 0
		self:SetPoseParameter("aim_yaw", 0)
		self:SetPoseParameter("aim_pitch", 0)
	end
	if self:GetPlaybackRate() ~= 1 then self:SetPlaybackRate(1) end
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
	self:NGLResolveSounds()

	local hp = self.NGLStartHealth or self.StartHealth
	self:SetHealth(hp)
	self:SetMaxHealth(hp)

	self:NGLSetMoveMode("walk")
	self.loco:SetAcceleration(900)
	self.loco:SetDeceleration(900)
	self.loco:SetStepHeight(18)

	-- NGL NPCs walk through each other (no blocked paths, no new paths to
	-- find in a crowd) and push each other aside instead (Core.PushCheck).
	-- Bullets, players, props and other NPCs still hit them.
	if not self.IsVehicleNPC and COLLISION_GROUP_NPC_SCRIPTED then
		self:SetCollisionGroup(COLLISION_GROUP_NPC_SCRIPTED)
	end
	-- Smaller (headcrabs) or bigger than a person.
	local hull = self.Hull
	if hull then self:SetCollisionBounds(hull[1], hull[2]) end
	-- How wide it really is (a poison zombie's box is wider than a person's),
	-- for keeping clear of players and each other (sv_core.lua).
	local _, cmax = self:GetCollisionBounds()
	if cmax and cmax.x > 0 then self.NGLRadius = math.min(cmax.x, cmax.y) end
	-- Zombies: show the headcrab riding on it (sv_zombies.lua).
	if self.Headcrab and NGL.Zombie then NGL.Zombie.ShowCrab(self, true) end

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
	self.NGLMode = NGL.PickAIMode and NGL.PickAIMode(self) or nil
	self.NGLNavCaps = NGL.Nav and NGL.Nav.Caps and NGL.Nav.Caps(self) or nil -- jumps and drops its paths may use
	if self.loco.SetDeathDropHeight then self.loco:SetDeathDropHeight(math.max(self.JumpDown or 0, 200) + 64) end
	self.NGLNextIdleSound = CurTime() + math.Rand(self.IdleSoundDelay[1], self.IdleSoundDelay[2])

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
-- ACT_RUN). Outside full-detail range the cheaper FrameAdvance is enough.
function ENT:BodyUpdate()
	self:NGLUpdateMoveYaw()
	if self.NGLMoving and self.NGLDetail then
		self:BodyMoveXY() -- also advances the frame
	else
		self:FrameAdvance()
	end
end

-- Legs follow the direction we actually move in (strafing, or walking while
-- the body is still turning), every tick and eased, so they never lag behind
-- or snap. Anywhere a player can see the NPC (ngl_ai_visual_range), not only
-- in full-detail range: a strafing NPC at 2000 units with its legs pointing
-- forward looks wrong. Further out the legs are put straight, and those NPCs
-- face where they walk (BehaveUpdate), so straight legs are right there.
local MOVE_YAW_RATE = 720 -- degrees per second the legs can swing
function ENT:NGLUpdateMoveYaw()
	if not self.NGLPoses.move then return end
	local target = 0
	if self.NGLMoving and self.NGLNear then
		local v = self.loco:GetVelocity()
		local dx, dy = v.x, v.y
		if dx * dx + dy * dy < 400 then
			-- Just starting (or pushing against something): the velocity is
			-- too small to trust, use where we are heading instead.
			local g = self.NGLSteer
			if g then
				local pos = self:GetPos()
				dx, dy = g.x - pos.x, g.y - pos.y
			end
		end
		if dx * dx + dy * dy > 1 then
			target = AngleDiff(deg(atan2(dy, dx)), self:GetAngles().y)
		end
	end
	local cur = self.NGLMoveYaw or 0
	local diff = AngleDiff(target, cur)
	if diff == 0 then return end
	local step = MOVE_YAW_RATE * engine.TickInterval()
	if diff > step then diff = step elseif diff < -step then diff = -step end
	cur = math.NormalizeAngle(cur + diff)
	self.NGLMoveYaw = cur
	self:SetPoseParameter("move_yaw", cur)
end

-- The stock NextBot runs RunBehaviour as a coroutine every tick. We skip that
-- entirely: decisions happen in the central scheduler at a lower rate, and the
-- per-tick part below only steers towards the goal it picked.
function ENT:BehaveStart() end
function ENT:RunBehaviour() end

function ENT:BehaveUpdate(interval)
	if self.NGLDying then return end
	local t0 = SysTime()
	-- A melee blow lands on its tick, not on the next AI think (up to a
	-- tenth of a second later, more in a big fight), so it matches the swing.
	local hitAt = self.NGLMeleeHitAt
	if hitAt and CurTime() >= hitAt then NGL.Core.ResolveMelee(self) end

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
			local reach = self.WaypointRadius
			local r2 = reach and reach * reach or WAYPOINT_SQR
			if path.tight and path.tight[idx] then r2 = math.min(r2, TIGHT_SQR) end
			if dx * dx + dy * dy < r2 and not self.NGLTraverse then
				-- At a ledge or gap on the path: jump (or climb) to the next point.
				local L = path.links and path.links[idx]
				idx = idx + 1
				self.NGLPathIdx = idx
				wp = path[idx]
				if L and L.move and wp then self:NGLStartTraverse(L.move, wp, L.h) end
			end
		end
		if wp then
			goal = wp
		else
			self.NGLPath = nil
		end
	end
	local onPath = goal ~= nil

	-- In the air or climbing: nothing else until we're there.
	if self.NGLTraverse then
		self:NGLTraverseUpdate(CurTime())
		local B = NGL.Bench
		if B then B.LuaTime = B.LuaTime + (SysTime() - t0) end
		return
	end
	-- Leaping at someone (sv_leap.lua): one touch check a tick until it lands.
	if self.NGLLeapState then
		NGL.Leap.Update(self, CurTime())
		local B = NGL.Bench
		if B then B.LuaTime = B.LuaTime + (SysTime() - t0) end
		return
	end

	-- Pushed by another NGL NPC walking into us (Core.PushCheck), or two
	-- standing inside each other (Core.OverlapCheck): moved aside a little
	-- this tick. Nobody's path changes; NGL NPCs don't collide with each
	-- other at all.
	if self.NGLShove then
		local to = NGL.Core.ShoveStep(self, pos, interval, CurTime())
		if to then pos = to end
	end

	if not goal then
		goal = self.NGLGoal
		local reach = self.WaypointRadius
		if goal and pos:DistToSqr(goal) < (reach and reach * reach or NEAR_GOAL_SQR) then
			goal = nil
			self.NGLGoal = nil
		end
	end

	-- A one-off animation (PlayAnim, melee swing) owns the body until it ends.
	if self.NGLAnimUntil then
		if CurTime() < self.NGLAnimUntil then
			if goal and not self.NGLAnimLock then self.loco:Approach(goal, 1) end
			self.NGLMoving = goal ~= nil and not self.NGLAnimLock
			self.NGLSteer = self.NGLMoving and goal or nil
			local f = self.NGLFace
			if f then self.loco:FaceTowards(f) end
			local B = NGL.Bench
			if B then B.LuaTime = B.LuaTime + (SysTime() - t0) end
			return
		end
		self.NGLAnimUntil = nil
		self.NGLAct = nil -- restart the normal activity
		self:SetPlaybackRate(1)
	end

	-- Vehicles steer and drive themselves (ENT:NGLDrive, see ngl_apc.lua):
	-- no animations, no turning on the spot.
	if self.NGLDrive then
		self:NGLDrive(goal, interval)
		self.NGLSteer = goal
		local B = NGL.Bench
		if B then B.LuaTime = B.LuaTime + (SysTime() - t0) end
		return
	end

	local now = CurTime()
	-- Walking into a wall or door frame (Core.SlideAlongWall): slide along it
	-- for a moment.
	local un = self.NGLUnstick
	if un then
		if now >= un.untilT then
			self.NGLUnstick = nil
		elseif goal then
			local dx, dy = goal.x - pos.x, goal.y - pos.y
			local l = math.sqrt(dx * dx + dy * dy)
			if l > 1 then
				goal = Vector(pos.x + dx / l * 24 + un.x * 48, pos.y + dy / l * 24 + un.y * 48, goal.z)
			end
		else
			goal = Vector(pos.x + un.x * 48, pos.y + un.y * 48, pos.z)
		end
	end
	-- Not on a path (walking straight at someone, strafing, stepping aside):
	-- don't walk off a drop. One short trace down just ahead (not the grid,
	-- which may be patchy at door frames and wall corners), again every
	-- 0.25 s, every EDGE_MOVE units walked, or when we turn.
	if goal and not onPath and not self.IsVehicleNPC then
		local dx, dy = goal.x - pos.x, goal.y - pos.y
		local l = math.sqrt(dx * dx + dy * dy)
		if l > 1 then
			dx, dy = dx / l, dy / l
			local E = self.NGLEdge
			if not E or now >= E.t or dx * E.x + dy * E.y < 0.7
				or (pos.x - E.px) ^ 2 + (pos.y - E.py) ^ 2 > EDGE_MOVE * EDGE_MOVE then
				local look = math.min(l, EDGE_LOOK)
				edgeTrace.start = Vector(pos.x + dx * look, pos.y + dy * look, pos.z + 24)
				edgeTrace.endpos = Vector(pos.x + dx * look, pos.y + dy * look, pos.z - EDGE_DROP)
				edgeTrace.filter = self
				local tr = util.TraceLine(edgeTrace)
				-- Inside something (a wall ahead) isn't a drop: walking into a
				-- wall is for the stuck check.
				E = { t = now + 0.25, x = dx, y = dy, px = pos.x, py = pos.y, blocked = not tr.Hit and not tr.StartSolid }
				self.NGLEdge = E
			end
			if E.blocked then
				goal = nil
				-- Going straight at someone: take a path round instead.
				if self.NGLDirect then self.NGLForcePathUntil = now + 5 end
			end
		end
	end

	-- Aimed variants (with their extra aim layers) only in full-detail range;
	-- further away the plain cycles look the same at that size.
	local A = self.NGLActs
	local fighting = self.NGLDetail and self.NGLEnemy ~= nil
	local crouch = self.NGLCrouch
	if goal then
		if self.DriveLikeVehicle then
			-- Vehicles drive forward: turn towards the goal first, then go.
			local off = math.abs(AngleDiff(deg(atan2(goal.y - pos.y, goal.x - pos.x)), self:GetAngles().y))
			if off < 40 then self.loco:Approach(goal, 1) end
		else
			self.loco:Approach(goal, 1)
		end
		self.NGLMoving = true
		local f = self.NGLFace
		local aim = fighting and f ~= nil
		if aim and self.NGLMoveMode ~= "walk" then
			-- Running faces the way we go (see below); the aimed run only
			-- when the target is roughly ahead, the gun can't point backwards.
			local dx, dy, ex, ey = goal.x - pos.x, goal.y - pos.y, f.x - pos.x, f.y - pos.y
			local dot = dx * ex + dy * ey
			aim = dot > 0 and dot * dot > 0.25 * (dx * dx + dy * dy) * (ex * ex + ey * ey)
		end
		if crouch and A.CrouchWalk then
			self:NGLSetAct(A.CrouchWalk)
		elseif self.NGLMoveMode == "walk" then
			self:NGLSetAct(aim and A.WalkAim or A.Walk)
		else
			self:NGLSetAct(aim and A.RunAim or A.Run)
		end
	elseif crouch and A.CrouchIdle then
		self.NGLMoving = false
		self:NGLSetAct(fighting and A.CrouchAim or A.CrouchIdle)
	else
		self.NGLMoving = false
		self:NGLSetAct(fighting and A.IdleAim or A.Idle)
	end

	-- Walking (strafing) keeps the body on the target while the legs step
	-- sideways; running sideways or backwards looks broken, so a running NPC
	-- turns to where it goes.
	-- Out of every player's sight the legs stay straight (NGLUpdateMoveYaw),
	-- so walk where we face there too.
	self.NGLSteer = goal
	local face = self.NGLFace
	if goal and (not face or self.NGLMoveMode ~= "walk" or not self.NGLNear or self.DriveLikeVehicle) then face = goal end
	if face then
		if goal then
			self.NGLTurning = nil
			self.loco:FaceTowards(face)
		else
			-- Standing or crouched: the upper body aims (aim_yaw) and the feet
			-- stay planted; the whole body only turns once the target is well
			-- off to the side, then all the way round. Turning in place every
			-- tick made the feet slide and twist.
			local off = math.abs(AngleDiff(deg(atan2(face.y - pos.y, face.x - pos.x)), self:GetAngles().y))
			if off > 45 then self.NGLTurning = true elseif off < 8 then self.NGLTurning = nil end
			if self.NGLTurning then self.loco:FaceTowards(face) end
		end
	end

	local B = NGL.Bench
	if B then B.LuaTime = B.LuaTime + (SysTime() - t0) end
end

-- Getting along a nav link (sv_nav.lua):
--   jump   down a ledge or across a gap: the engine's jump, with the Jump,
--          Glide and Land animations
--   up     onto a ledge, or over something in the way (a low wall, through a
--          window, over a hole): a short hop up and over (JumpUp, then Land)
--   climb  up or down a climb link (ENT.Climb): straight up the wall and over
--          the top, or over the edge and straight down (ClimbUp, ClimbDown)
-- `up` and `climb` move the NPC along a set curve, so they always land
-- where the grid says.
local UP_TIME = 0.45     -- s for a hop up, plus a little per unit of height
local UP_CLEAR = 16      -- how far above the ledge the hop goes
local climbTrace = { mask = MASK_NPCSOLID_BRUSHONLY }

-- `h`: the link's height (start above landing); for a jump over something
-- (a vault), minus how high it has to go.
function ENT:NGLStartTraverse(move, to, h)
	local now = CurTime()
	local from = self:GetPos()
	local A = self.NGLActs
	local dir = to - from
	dir.z = 0
	if dir.x ~= 0 or dir.y ~= 0 then
		self:SetAngles(Angle(0, math.deg(math.atan2(dir.y, dir.x)), 0))
		dir:Normalize()
	end
	local T = { move = move, from = from, to = to, t0 = now }
	self.NGLTraverse = T
	self.NGLMoving, self.NGLSteer = false, nil
	local rise = to.z - from.z
	if move == "up" then
		-- High enough to clear the ledge, or what's in the way of a vault.
		T.clear = math.max(rise, h and -h or 0)
		T.dur = UP_TIME + math.max(T.clear, 0) / 400
		local anim = A.JumpUp or A.Jump
		if anim then self:PlayAnim(anim, false) end
	elseif move == "climb" then
		-- To the foot of the wall, up it, over the top (or the other way
		-- round going down). The wall is found with one trace from the
		-- bottom end towards the top end, so the NPC climbs the wall itself,
		-- not the air in front of it.
		local up = rise >= 0
		local low, high = up and from or to, up and to or from
		local d = high - low
		d.z = 0
		local len = d:Length()
		local foot = 0
		if len > 1 then
			d:Mul(1 / len)
			climbTrace.start = Vector(low.x, low.y, low.z + 26)
			climbTrace.endpos = Vector(low.x + d.x * len, low.y + d.y * len, low.z + 26)
			climbTrace.filter = self
			local tr = util.TraceLine(climbTrace)
			if tr.Hit and not tr.StartSolid then foot = math.max(tr.Fraction * len - 16, 0) end
		end
		local wall = Vector(low.x + d.x * foot, low.y + d.y * foot, low.z)
		local wallTop = Vector(wall.x, wall.y, high.z)
		local pts = up and { from, wall, wallTop, to } or { from, wallTop, wall, to }
		local rate = self.ClimbRate or 250
		local times = { 0 }
		for k = 2, 4 do
			local seg = pts[k] - pts[k - 1]
			local vertical = k == 3
			times[k] = times[k - 1] + (vertical and math.max(math.abs(seg.z) / rate, 0.3) or math.max(seg:Length() / 200, 0.12))
		end
		T.pts, T.times = pts, times
		T.dur = times[4]
		local anim = up and A.ClimbUp or A.ClimbDown or A.ClimbUp or A.Glide
		T.anim = anim
		if anim then self:PlayAnim(anim, false) end
	else
		self.loco:JumpAcrossGap(to, dir)
		if A.Jump then self:PlayAnim(A.Jump, false) end
	end
end

-- Where a scripted move (up, climb) has got to at time t.
local function scriptedPos(T, t)
	local from, to = T.from, T.to
	local f = math.Clamp(t / T.dur, 0, 1)
	if T.move == "up" then
		-- Rise first, then forward over the edge and down onto it.
		local top = math.max(from.z + (T.clear or 0), to.z) + UP_CLEAR
		local z
		if f < 0.6 then
			z = from.z + (top - from.z) * math.sin(f / 0.6 * math.pi * 0.5)
		else
			z = top + (to.z - top) * ((f - 0.6) / 0.4) ^ 2
		end
		local g = f * f
		return Vector(from.x + (to.x - from.x) * g, from.y + (to.y - from.y) * g, z)
	end
	-- climb: along the corners worked out in NGLStartTraverse.
	local pts, times = T.pts, T.times
	for k = 2, 4 do
		if t <= times[k] or k == 4 then
			local a, b = pts[k - 1], pts[k]
			local span = times[k] - times[k - 1]
			local g = span > 0 and math.Clamp((t - times[k - 1]) / span, 0, 1) or 1
			return a + (b - a) * g
		end
	end
	return to
end

function ENT:NGLTraverseUpdate(now)
	local T = self.NGLTraverse
	local A = self.NGLActs
	self.NGLMoving = false
	local t = now - T.t0
	if T.move == "up" or T.move == "climb" then
		self:SetPos(t >= T.dur and T.to or scriptedPos(T, t))
		self.loco:SetVelocity(Vector(0, 0, 0))
		if t >= T.dur then
			self.NGLTraverse = nil
			if A.Land and T.move == "up" then self:PlayAnim(A.Land, false) end
		elseif T.anim and now >= (self.NGLAnimUntil or 0) then
			self:PlayAnim(T.anim, false) -- keep the climb going
		end
		return
	end
	if t > 0.25 and self.loco:IsOnGround() then
		self.NGLTraverse = nil
		if A.Land then self:PlayAnim(A.Land, false) end
	elseif t > 5 then
		self.NGLTraverse = nil -- never came down where expected: carry on
	elseif t > 0.25 and A.Glide and now >= (self.NGLAnimUntil or 0) then
		self:PlayAnim(A.Glide, false)
	end
end

function ENT:OnInjured(dmginfo)
	local now = CurTime()
	if now >= (self.NGLNextFlinch or 0) then
		self.NGLNextFlinch = now + 1
		self:NGLGesture("Flinch")
	end
	self:NGLSound("Pain")

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
	self:NGLSound("Death")
	self:OnDeath(dmginfo)
	NGL.Core.Remove(self)
	self.NGLLeapState = nil
	-- Zombies: the headcrab jumps off (sv_zombies.lua), before the body
	-- becomes a ragdoll so the ragdoll is without it.
	if self.Headcrab and NGL.Zombie then NGL.Zombie.OnKilled(self, dmginfo) end

	local mode = cvRagdolls:GetInt()
	if mode ~= 0 and dmginfo:IsDamageType(DMG_DISSOLVE) then
		-- Dissolved (the AR2's energy ball): only a server ragdoll can
		-- dissolve, and the engine does it for this damage type.
		self:BecomeRagdoll(dmginfo)
	elseif mode == 2 then
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

----------------------------------------------------------------------------
-- Building blocks for custom behaviour
--
-- Call these from your hooks (OnAIThink, OnIdle, OnCombat, OnAttack...). They
-- are what the default behaviour is made of, so a custom NPC built from them
-- gets the same optimizations: budgeted path-finding, grid enemy search,
-- silent shots far from players, animation detail only near players.
----------------------------------------------------------------------------

local function core()
	Core = Core or NGL.Core
	return Core
end

local function posOf(target)
	if isvector(target) then return target end
	return target:GetPos()
end

-- Movement ---------------------------------------------------------------

-- Walk (or run) to `pos`, along the nav grid when needed. Calling it again
-- with the same spot while on the way does nothing, so it's fine every think.
function ENT:MoveTo(pos, run)
	self:NGLSetMoveMode(run and "run" or "walk")
	local last = self.NGLMoveToPos
	if last and last:DistToSqr(pos) < 32 * 32 and (self.NGLPath or self.NGLGoal or self.NGLPathPending) then return end
	self.NGLMoveToPos = Vector(pos.x, pos.y, pos.z)
	core().StopMoving(self)
	self.NGLDirect = nil
	core().Chase(self, CurTime(), self:GetPos(), self.NGLMoveToPos, false)
end

function ENT:StopMoving()
	core().StopMoving(self)
	self.NGLMoveToPos = nil
end

function ENT:IsMoving() return self.NGLMoving == true end

-- Crouch (lower eyes and shots; crouched animations). The default combat
-- behaviour crouches on its own (CrouchChance) and stands up to move.
function ENT:SetCrouching(crouch) self.NGLCrouch = crouch and self.NGLActs.CrouchIdle ~= nil or false end
function ENT:IsCrouching() return self.NGLCrouch == true end
function ENT:SetRunning(run) self:NGLSetMoveMode(run and "run" or "walk") end

-- Turn towards a position or entity (nil: face where we walk). The default
-- behaviour sets this every think, so set it from a hook that returns true.
function ENT:LookAt(target)
	self.NGLFace = target and posOf(target) or nil
end

-- Targets ----------------------------------------------------------------

function ENT:GetEnemy() return self.NGLEnemy end
function ENT:SetEnemy(ent) core().SetEnemy(self, ent) end
function ENT:FindEnemy() return core().FindEnemy(self, self:GetPos()) end -- nearest visible hostile, or nil
function ENT:CanSee(ent) return core().CanSee(self, ent) end              -- one trace from our eyes
function ENT:IsEnemyVisible() return self.NGLEnemy ~= nil and self.NGLEnemyVisible == true end
function ENT:GetLastSeenPos() return self.NGLLastSeenPos end
function ENT:IsHostileTo(ent) return core().IsHostile(self, ent) end

-- Friendly NGL NPCs within `radius` (spatial grid, cheap).
function ENT:GetAllies(radius)
	local faction = self.Faction
	return core().FindInRadius(self:GetPos(), radius, function(e)
		return e ~= self and NGL.GetRelation(faction, e.Faction) == D_LI
	end)
end

-- Combat -----------------------------------------------------------------

-- Fire the NPC's Weapon at an entity: bullets, or projectiles if the weapon
-- has a Projectile table. Far from players it's one silent trace.
function ENT:FireWeapon(target, shots)
	if not self.Weapon or not IsValid(target) then return false end
	core().Fire(self, target, shots or 1, self.NGLNear)
	return true
end

-- Start a melee swing at `target` using the Melee table (ignores the cooldown).
function ENT:MeleeAttack(target)
	return core().StartMelee(self, target, CurTime())
end

-- Launch a projectile (see sv_projectile.lua for the fields of `def`) at an
-- entity or position. `def` defaults to the weapon's Projectile.
function ENT:FireProjectile(target, def)
	def = def or (self.Weapon and self.Weapon.Projectile)
	if not def then return false end
	local src = self:GetPos()
	src.z = src.z + self.EyeHeight
	local dst = isvector(target) and target or target:WorldSpaceCenter()
	NGL.Proj.Fire(self, def, src, dst, self.NGLNear)
	return true
end

function ENT:DealDamage(target, amount, dmgType, force)
	core().Damage(self, target, amount, dmgType, nil, force)
end

-- Leap at an entity or a position (sv_leap.lua), with `def` or the NPC's
-- LeapAttack. Ignores the range and the cooldown; CanLeap checks those.
function ENT:Leap(target, def)
	def = def or self.LeapAttack
	if not def then return false end
	return NGL.Leap.Start(self, target, def, CurTime())
end
-- Could it leap at `ent` right now (range, height, cooldown, clear way)?
function ENT:CanLeap(ent, def)
	if not IsValid(ent) then return false end
	return NGL.Leap.Can(self, ent, self:GetPos():Distance(ent:GetPos()), CurTime(), def or self.LeapAttack)
end
function ENT:IsLeaping() return self.NGLLeapState ~= nil end

-- Animation --------------------------------------------------------------

-- Play an activity (ACT_*) or sequence name once over the whole body.
-- lock (default true): stand still and skip AI decisions until it ends.
-- Returns its duration in seconds, or false if the model doesn't have it.
function ENT:PlayAnim(anim, lock, rate)
	rate = rate or 1
	local seq = isstring(anim) and self:LookupSequence(anim) or self:SelectWeightedSequence(anim)
	if not seq or seq < 0 then return false end
	-- ResetSequence, not SetSequence: it also tells clients the animation
	-- started over. With SetSequence a dedicated server's clients didn't see
	-- a sequence restart (the same melee swing, jump or climb twice in a
	-- row) and blended the old cycle into the new one, so the animation
	-- jumped or played out of step (singleplayer hides it).
	self:ResetSequence(seq)
	self:ResetSequenceInfo()
	self:SetCycle(0)
	self:SetPlaybackRate(rate)
	local dur = self:SequenceDuration(seq) / rate
	local now = CurTime()
	self.NGLAnimSeq = seq
	self.NGLAnimUntil = now + dur
	self.NGLAnimLock = lock ~= false
	if self.NGLAnimLock then
		core().StopMoving(self)
		self.NGLBusyUntil = math.max(self.NGLBusyUntil or 0, now + dur)
	end
	return dur
end

-- Play an activity (ACT_GESTURE_*) or sequence name over the current
-- animation. Skipped outside ngl_anim_detail_range, like built-in gestures.
function ENT:PlayGesture(anim)
	if not self.NGLDetail then return false end
	if isstring(anim) then
		local seq = self:LookupSequence(anim)
		if not seq or seq < 0 then return false end
		self:AddGestureSequence(seq)
	else
		self:RestartGesture(anim)
	end
	return true
end

-- The melee swing's own timing: HL2's zombies hurt you on their model's
-- animation events (AE_ZOMBIE_ATTACK_RIGHT, _LEFT, _BOTH), at a set point of
-- the swing, not after a fixed delay. A fixed HitDelay made the poison
-- zombie's blow land well after its claw came down. So the .mdl is read
-- once per model and sequence (a few file reads, cached; never in a fight)
-- for the cycles of those events. Sequences from $includemodel files are
-- looked up there by name. None found: Melee.HitDelay as before.
local HIT_EVENTS = { AE_ZOMBIE_ATTACK_RIGHT = true, AE_ZOMBIE_ATTACK_LEFT = true, AE_ZOMBIE_ATTACK_BOTH = true }
local SEQDESC_SIZE, EVENT_SIZE = 212, 80 -- mstudioseqdesc_t, mstudioevent_t (studio.h, MDL 44-49)
local hitCycles = {} -- [model .. "|" .. sequence name] = { cycle, ... } or false

local function readString(f, at)
	f:Seek(at)
	local raw = f:Read(64)
	return raw and raw:match("^[^%z]*") or ""
end

-- Cycles of the hit events of the sequence called `label` in `path`.
-- nil: no such sequence there; false: it has none. `depth`: include models.
local function scanModel(path, label, depth, events)
	local f = file.Open(path, "rb", "GAME")
	if not f then return nil end
	local result
	local ok = pcall(function()
		f:Seek(4)
		local ver = f:ReadLong()
		if not ver or ver < 44 or ver > 49 then return end
		f:Seek(188)
		local nseq, seqidx = f:ReadLong(), f:ReadLong()
		if nseq and nseq > 0 and nseq < 4096 then
			for s = 0, nseq - 1 do
				local base = seqidx + s * SEQDESC_SIZE
				f:Seek(base + 4)
				local labelAt = f:ReadLong()
				if string.lower(readString(f, base + labelAt)) == label then
					f:Seek(base + 24)
					local nev, evidx = f:ReadLong(), f:ReadLong()
					result = false
					for k = 0, math.min(nev or 0, 64) - 1 do
						local e = base + evidx + k * EVENT_SIZE
						f:Seek(e)
						local cycle = f:ReadFloat()
						f:Seek(e + 76)
						local nameAt = f:ReadLong()
						if nameAt and nameAt > 0 and events[readString(f, e + nameAt)] and cycle then
							result = result or {}
							result[#result + 1] = math.Clamp(cycle, 0, 1)
						end
					end
					return
				end
			end
		end
		if depth <= 0 then return end
		f:Seek(336)
		local ninc, incidx = f:ReadLong(), f:ReadLong()
		local includes = {}
		for k = 0, math.min(ninc or 0, 16) - 1 do
			local g = incidx + k * 8
			f:Seek(g + 4)
			local nameAt = f:ReadLong()
			local name = nameAt and readString(f, g + nameAt)
			if name and name ~= "" then includes[#includes + 1] = name end
		end
		f:Close()
		f = nil
		for _, inc in ipairs(includes) do
			if not string.StartWith(string.lower(inc), "models/") then inc = "models/" .. inc end
			local r = scanModel(inc, label, depth - 1, events)
			if r ~= nil then result = r return end
		end
	end)
	if f then f:Close() end
	if not ok then return nil end
	if result then table.sort(result) end
	return result
end

-- Seconds into an animation of `dur` seconds at which the model's events
-- named in `events` (a set; default the melee hit events) fire, or nil.
function ENT:NGLEventTimes(seq, dur, events)
	if not seq or seq < 0 then return nil end
	events = events or HIT_EVENTS
	local model = self:GetModel()
	local label = string.lower(self:GetSequenceName(seq) or "")
	if label == "" then return nil end
	local key = model .. "|" .. label .. "|" .. table.concat(table.GetKeys(events), ",")
	local c = hitCycles[key]
	if c == nil then
		c = scanModel(model, label, 2, events) or false
		hitCycles[key] = c
	end
	if not c then return nil end
	local t = {}
	for k, cy in ipairs(c) do t[k] = cy * dur end
	return t
end
function ENT:NGLHitTimes(seq, dur) return self:NGLEventTimes(seq, dur, HIT_EVENTS) end

-- The model's hit events as the engine plays them, where it hands them to
-- us: the blow lands right on the claw's frame.
local GetAnimEventName = util.GetAnimEventNameByID
function ENT:HandleAnimEvent(event, eventTime, cycle, typ, options)
	if not (self.NGLMeleeHitAt and GetAnimEventName) then return end
	local name = GetAnimEventName(event)
	if name and HIT_EVENTS[name] then
		self.NGLLiveHits = true
		NGL.Core.ResolveMelee(self)
	end
end

-- The melee swing animation: Melee.Anim (or Anims.Melee). Full body unless
-- Melee.Gesture is true. Returns the duration for a full-body swing.
function ENT:NGLPlayMeleeAnim()
	local m = self.Melee
	local act = m.Anim or self.NGLActs.Melee
	if not act then return nil end
	if m.Gesture then
		self:PlayGesture(act)
		return nil
	end
	local dur = self:PlayAnim(act, true, m.AnimRate)
	return dur or nil, dur and self.NGLAnimSeq or nil
end

-- Sound ------------------------------------------------------------------

-- Say a line: a kind from ENT.Sounds ("Alert", "Pain", ...) or a sound path.
function ENT:Speak(what)
	if self.NGLSounds[what] then
		self:NGLSound(what)
	elseif self.NGLNear then
		self:EmitSound(what, self.SoundLevel, self.SoundPitch, 1, CHAN_VOICE)
	end
end

-- State ------------------------------------------------------------------

function ENT:IsNearPlayer() return self.NGLNear == true end  -- within ngl_ai_visual_range
function ENT:IsDetailed() return self.NGLDetail == true end  -- within ngl_anim_detail_range
function ENT:IsBusy() return CurTime() < (self.NGLBusyUntil or 0) end

-- Orders and squads (sv_core.lua, sv_squad.lua) ---------------------------

-- order = { kind = "hold" | "move" | "search" | "fire_at" (or one of
-- ENT.OrderKinds), time = seconds, plus per kind:
--   hold:    face = pos, crouch = false to stand
--   move:    pos, run = bool, radius = arrive distance, hold = true to hold
--            there afterwards (holdTime)
--   search:  pos, radius (400), run = false to walk there
--   fire_at: pos, spread (150)
--   any:     onDone = function(npc, order, reason) }
-- reason passed to OnOrderDone/onDone: "timeout", "done", "contact",
-- "replaced", "cleared".
function ENT:GiveOrder(order) return core().GiveOrder(self, order, CurTime()) end
function ENT:GetOrder() return self.NGLOrder end
function ENT:ClearOrder() core().EndOrder(self, "cleared") end

-- AI mode (sv_aimodes.lua): "balanced", "assault", "flanker", "defender" or
-- one registered with NGL.RegisterAIMode. Returns false for an unknown name.
function ENT:SetAIMode(name)
	local m = NGL.AIModes and NGL.AIModes[name]
	if not m then return false end
	self.NGLMode = m
	return true
end
function ENT:GetAIMode() return self.NGLMode and self.NGLMode.Name or "balanced" end

function ENT:GetSquad() return self.NGLSquad end
function ENT:IsSquadLeader() return self.NGLSquad ~= nil and self.NGLSquad.leader == self end
-- A new squad led by this NPC (leaves its old one). maxSize counts the leader.
function ENT:MakeSquad(maxSize) return NGL.NewSquad(self, maxSize or 10) end
function ENT:LeaveSquad() if self.NGLSquad then self.NGLSquad:Remove(self) end end
