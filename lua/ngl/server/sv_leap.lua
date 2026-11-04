-- NGL leap attacks: headcrabs jumping at your face, fast zombies pouncing.
--
-- An NPC with ENT.LeapAttack (fields in ngl_base/shared.lua) and no gun
-- leaps at an enemy it can see when it's in range and the way is clear
-- (sv_core.lua does this in the default fight; self:Leap(target) does it
-- from your own hooks). The jump is the engine's (loco:JumpAcrossGap), or
-- a set launch velocity for something thrown (a poison zombie's crab).
--
-- Cost: Can() is a few comparisons and, only when everything else says
-- yes, one hull trace. While in the air the NPC does one distance check a
-- tick against its target (NearestPoint) until it lands, and skips its
-- usual movement and AI. Nothing runs for NPCs that aren't leaping.

NGL.Leap = NGL.Leap or {}
local L = NGL.Leap

local IsValid, CurTime = IsValid, CurTime
local random = math.random

local clearTrace = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }

local function pick(s)
	if type(s) == "table" then return s[random(#s)] end
	return s
end

-- Plays the first of `anims` (an activity, a sequence name, or a list of
-- them) the model has, over the whole body, without stopping the NPC.
local function playFirst(npc, anims)
	if anims == nil then return false end
	if type(anims) ~= "table" then anims = { anims } end
	for i = 1, table.maxn(anims) do
		local a = anims[i]
		if a and npc:PlayAnim(a, false) then return true end
	end
	return false
end
L.PlayFirst = playFirst

local function sayLine(npc, what)
	if not what or not npc.NGLNear then return end
	if npc.NGLSounds and npc.NGLSounds[what] then
		npc:NGLSound(what, true)
	else
		npc:EmitSound(pick(what), npc.SoundLevel, npc.SoundPitch, 1, CHAN_VOICE)
	end
end

-- Could `npc` leap at `target` (dist away) now?
function L.Can(npc, target, dist, now, def)
	def = def or npc.LeapAttack
	if not def or not IsValid(target) then return false end
	if npc.NGLLeapState or npc.NGLTraverse or now < (npc.NGLNextLeap or 0) then return false end
	if dist < (def.MinDist or 0) or dist > (def.MaxDist or 250) then return false end
	local pos, tPos = npc:GetPos(), target:GetPos()
	local dz = tPos.z - pos.z
	if dz > (def.MaxRise or 96) or dz < -(def.MaxDrop or 250) then return false end
	if not npc.loco:IsOnGround() then return false end
	if def.Chance and random() > def.Chance then
		npc.NGLNextLeap = now + 0.5
		return false
	end
	-- Nothing solid in the way (walls, railings): a hull a little smaller
	-- than the NPC, from just above its feet to the target's middle.
	local mins, maxs = npc:OBBMins(), npc:OBBMaxs()
	local t = clearTrace
	t.mins = Vector(mins.x * 0.7, mins.y * 0.7, 0)
	t.maxs = Vector(maxs.x * 0.7, maxs.y * 0.7, math.max((maxs.z - mins.z) * 0.5, 4))
	t.start = Vector(pos.x, pos.y, pos.z + 12)
	local c = target:WorldSpaceCenter()
	t.endpos = Vector(c.x, c.y, math.max(c.z - t.maxs.z * 0.5, tPos.z + 4))
	t.filter = npc
	local tr = util.TraceHull(t)
	if tr.StartSolid or (tr.Hit and tr.Fraction < 0.85) then
		npc.NGLNextLeap = now + 1 -- look again in a second
		return false
	end
	return true
end

-- HL2's leap (CFastZombie::LeapAttack, also the headcrab's): straight at
-- the target's middle, as high as it needs to get there (16..120 units up),
-- sideways speed to arrive just then, at most 1000 units/s in all.
local function hl2Velocity(npc, tPos, g)
	local pos = npc:GetPos()
	g = math.max(g or 1000, 1)
	local height = math.Clamp(tPos.z - pos.z, 16, 120)
	local speed = math.sqrt(2 * g * height)
	local time = speed / g
	local v = (tPos - pos) * (1 / time)
	v.z = speed
	local len = v:Length()
	if len > 1000 then v:Mul(1000 / len) end
	return v
end

local function aimPos(ent, def)
	-- HL2 jumps at the middle of the target; others at its feet, led a little.
	if def.Velocity == "hl2" then return ent:WorldSpaceCenter() end
	local tPos = ent:GetPos()
	local v = ent:GetVelocity()
	local lead = def.Lead or 0.25
	return Vector(tPos.x + v.x * lead, tPos.y + v.y * lead, tPos.z)
end

local function face(npc, tPos)
	local d = tPos - npc:GetPos()
	if d.x ~= 0 or d.y ~= 0 then npc:SetAngles(Angle(0, math.deg(math.atan2(d.y, d.x)), 0)) end
end

-- Takes off (after the wind-up, if any).
local function launch(npc, S, now, opts)
	local def, ent = S.def, S.target
	local tPos = IsValid(ent) and aimPos(ent, def) or S.pos
	local pos = npc:GetPos()
	local dir = tPos - pos
	dir.z = 0
	if dir:LengthSqr() < 1 then dir = npc:GetForward() dir.z = 0 end
	dir:Normalize()
	npc:SetAngles(Angle(0, dir:Angle().y, 0))
	if opts and opts.vel then
		npc.loco:Jump()
		npc.loco:SetVelocity(opts.vel)
	elseif def.Velocity == "hl2" then
		npc.loco:Jump()
		npc.loco:SetVelocity(hl2Velocity(npc, tPos, npc.loco:GetGravity()))
	else
		-- Aim a little past it so we reach it before coming down.
		local over = def.Overshoot or 24
		npc.loco:JumpAcrossGap(Vector(tPos.x + dir.x * over, tPos.y + dir.y * over, tPos.z), dir)
	end
	S.phase, S.t0 = nil, now
	playFirst(npc, def.Anim)
	sayLine(npc, def.Sound)
end

-- Leap at `target` (an entity or a position). opts.vel: launch with this
-- velocity instead of the engine's jump (for something thrown, already in
-- the air). Returns true when it took off (or started winding up).
-- def.WindUp: seconds crouched for the jump first (def.WindUpAnim, its
-- def.WindUpEvent from the model when it has one, like HL2's fast zombie's
-- AE_FASTZOMBIE_LEAP), turning to keep facing the target; def.WindUpSound.
function L.Start(npc, target, def, now, opts)
	def = def or npc.LeapAttack
	if not def or npc.NGLDying then return false end
	local ent = not isvector(target) and IsValid(target) and target or nil
	local tPos
	if ent then
		tPos = ent:GetPos()
	elseif isvector(target) then
		tPos = target
	else
		return false
	end

	NGL.Core.StopMoving(npc)
	npc.NGLCrouch = false
	npc.NGLMoving, npc.NGLSteer = false, nil
	face(npc, tPos)

	local S = { target = ent, pos = tPos, def = def, t0 = now, hit = false }
	npc.NGLLeapState = S
	npc.NGLNextLeap = now + (def.Delay or 3)
	npc.NGLBusyUntil = now + 5 -- no AI decisions in the air; set again on landing
	npc.NGLFace = nil

	local wind = not (opts and opts.vel) and def.WindUp
	if wind then
		local t = type(wind) == "number" and wind or 0.4
		local played = false
		local anims = def.WindUpAnim
		if type(anims) ~= "table" then anims = { anims } end
		for i = 1, table.maxn(anims) do
			local a = anims[i]
			local dur = a and npc:PlayAnim(a, false)
			if dur then
				played = true
				local ev = def.WindUpEvent and npc.NGLEventTimes and npc:NGLEventTimes(npc.NGLAnimSeq, dur, { [def.WindUpEvent] = true })
				if ev and ev[1] then t = ev[1] end
				-- The engine hands this NPC its events as they play: the
				-- jump goes on the event itself (L.OnEvent); this is only a
				-- fallback, a little later.
				if def.WindUpEvent and npc.NGLLiveEvents then t = t + 0.35 end
				if GetConVar("ngl_debug_melee"):GetBool() then
					print(string.format("[NGL] %s wind-up %s (%.2f s): jumps at %.2f s (%s)", npc:GetClass(),
						npc:GetSequenceName(npc.NGLAnimSeq) or "?", dur, t, (ev and ev[1]) and "model event" or "WindUp"))
				end
				break
			end
		end
		if played or t > 0 then
			S.phase, S.launchAt = "windup", now + t
			sayLine(npc, def.WindUpSound)
			return true
		end
	end
	launch(npc, S, now, opts)
	return true
end

-- An animation event while leaping (ENT:HandleAnimEvent): the wind-up's
-- jump event takes off right then.
function L.OnEvent(npc, name)
	local S = npc.NGLLeapState
	if S and S.phase == "windup" and S.def.WindUpEvent == name then
		launch(npc, S, CurTime())
	end
end

-- Throw velocity for something launched from `src` to land on `dst`
-- (gravity `g`), taking `time` seconds.
function L.Ballistic(src, dst, g, time)
	local v = (dst - src) * (1 / time)
	v.z = v.z + 0.5 * g * time
	return v
end

-- Damage for a leap hitting `target`.
local function hurt(npc, target, def, dir)
	local amount, kind = def.Damage or 10, def.DamageType or DMG_SLASH
	if def.Poison then
		kind = DMG_POISON
		if target:IsPlayer() then
			-- HL2's poison headcrab: down to 1 health; the player gets it back
			-- over the next seconds (the engine's poison recovery).
			local hp = target:Health()
			if hp > amount + 1 then amount = hp - 1 end
		else
			amount = def.NPCDamage or amount
		end
	end
	NGL.Core.Damage(npc, target, amount, kind, target:WorldSpaceCenter(), dir * (def.Force or 200))
end

-- Every tick while leaping (ENT:BehaveUpdate).
function L.Update(npc, now)
	local S = npc.NGLLeapState
	local def = S.def
	if S.phase == "windup" then
		local ent = S.target
		if ent and (not IsValid(ent) or ent.NGLDying or ent:Health() <= 0) then
			-- Nothing to jump at any more: stand up again.
			npc.NGLLeapState = nil
			npc.NGLBusyUntil = now
			npc.NGLAct, npc.NGLAnimUntil = nil, nil
			return
		end
		if ent then face(npc, ent:GetPos()) end
		if now >= S.launchAt then launch(npc, S, now) end
		return
	end
	local t = now - S.t0
	local target = S.target
	if not S.hit and target then
		if not IsValid(target) or (target.NGLDying) or target:Health() <= 0 then
			S.target = nil
		else
			local c = npc:WorldSpaceCenter()
			local r = def.Reach or 32
			if target:NearestPoint(c):DistToSqr(c) < r * r then
				S.hit = true
				local dir = npc.loco:GetVelocity()
				dir.z = 0
				dir:Normalize()
				hurt(npc, target, def, dir)
				if npc.NGLNear and def.HitSound then npc:EmitSound(pick(def.HitSound)) end
				-- Stop on it instead of flying on through; a headcrab
				-- (def.Bounce) bounces back off it as in HL2, so it doesn't
				-- land on your head, out of reach of your gun.
				local v = npc.loco:GetVelocity()
				if def.Bounce then
					npc.loco:SetVelocity(Vector(-dir.x * 120, -dir.y * 120, math.max(v.z, 0) * 0.3))
				else
					npc.loco:SetVelocity(Vector(v.x * 0.15, v.y * 0.15, math.min(v.z, 0)))
				end
				npc:OnLeapHit(target, true)
			end
		end
	end
	if (t > 0.2 and npc.loco:IsOnGround()) or t > 4 then
		npc.NGLLeapState = nil
		npc.NGLBusyUntil = now + (def.Recover or 0.4)
		npc.NGLAct = nil -- back to the normal animation after the landing
		if not playFirst(npc, def.LandAnim) then npc.NGLAnimUntil = nil end
		if not S.hit then npc:OnLeapHit(S.target, false) end
		-- Think again as soon as it can act.
		if npc.NGLNextThink and npc.NGLNextThink > npc.NGLBusyUntil then npc.NGLNextThink = npc.NGLBusyUntil end
	end
end
