-- NGL projectiles: rockets, grenades, spit... without entities.
--
-- A projectile is a few numbers in a table, moved with one trace per tick.
-- Clients get one small net message when it is fired and one when it lands,
-- and draw it themselves. Far from every player there is no flight at all:
-- the shot lands at once with the weapon's expected accuracy, the same way
-- far-away bullets work. Spawning a real entity per rocket (what most NPC
-- bases do) costs an edict, physics and networking for every shot.
--
-- Definition fields (all optional except Damage):
--   Damage      damage on hit (or at the centre of the blast)
--   Radius      > 0 makes it explode with util.BlastDamage (default 0: direct hit only)
--   Speed       units per second (1500)
--   Gravity     units per second^2 pulling it down (0 = straight line); lobbed shots aim to land on the target
--   Spread      random direction error (0.02)
--   Accuracy    hit chance when resolved without flight, far from players (0.6)
--   Life        seconds before it disappears (5)
--   Model       model drawn on clients ("" or nil draws a glow sprite)
--   DamageType  for direct hits (DMG_BULLET); blasts use DMG_BLAST
--   Effect      util.Effect name played on explosion ("Explosion"); false for none
--   HitSound    sound or list of sounds played where it lands
--   Homing      a guided rocket like HL2's APC missile: { Delay = 0.3 (seconds
--               coasting after launch), Turn = 90 (degrees per second it can
--               turn), Speed = 1500 (speed once lit), Accel = 2000 }. Fired
--               with opts.target it follows that entity, otherwise `dst`.
--   Trail       true: clients draw a smoke trail once it is lit
--
-- Proj.Fire(attacker, def, src, dst, visual, opts): opts.dir launches it in
-- that direction instead of straight at `dst`, opts.target is what a homing
-- projectile follows.

NGL.Proj = NGL.Proj or {}
local Proj = NGL.Proj

util.AddNetworkString("ngl_proj")
util.AddNetworkString("ngl_proj_end")

local list = {}
local nextId = 0
local trace = { mask = MASK_SHOT }
local result = {}
trace.output = result

local function pick(s)
	if type(s) == "table" then return s[math.random(#s)] end
	return s
end

local function land(def, attacker, pos, hitEnt)
	if not IsValid(attacker) then attacker = game.GetWorld() end
	if (def.Radius or 0) > 0 then
		util.BlastDamage(attacker, attacker, pos, def.Radius, def.Damage)
		if def.Effect ~= false then
			local ed = EffectData()
			ed:SetOrigin(pos)
			util.Effect(def.Effect or "Explosion", ed, true, true)
		end
	elseif IsValid(hitEnt) then
		local dmg = DamageInfo()
		dmg:SetDamage(def.Damage)
		dmg:SetDamageType(def.DamageType or DMG_BULLET)
		dmg:SetAttacker(attacker)
		dmg:SetInflictor(attacker)
		dmg:SetDamagePosition(pos)
		hitEnt:TakeDamageInfo(dmg)
	end
	if def.HitSound then sound.Play(pick(def.HitSound), pos, 80, 100) end
end

-- Fires `def` from `src` towards the world position `dst`. `visual` = a
-- player is close enough to see it (otherwise it resolves at once).
function Proj.Fire(attacker, def, src, dst, visual, opts)
	if not visual then
		if math.random() < (def.Accuracy or 0.6) then
			-- A little past the aim point, so it reaches into small targets
			-- (see the silent shot in sv_core.lua); blasts land at the aim point.
			local d = dst - src
			local len = d:Length()
			local past = (def.Radius or 0) > 0 and 0 or 48
			trace.start, trace.endpos, trace.filter = src, len > 1 and dst + d * (past / len) or dst, attacker
			util.TraceLine(trace)
			local target = opts and opts.target
			local hitEnt = result.Entity
			if IsValid(target) and hitEnt ~= target and result.Fraction * (len + past) >= len - 4 then hitEnt = target end
			land(def, attacker, result.HitPos, hitEnt)
		end
		return
	end

	local speed = def.Speed or 1500
	local dir = (opts and opts.dir) or (dst - src)
	local dist = (dst - src):Length()
	dir = Vector(dir.x, dir.y, dir.z)
	dir:Normalize()
	local spread = def.Spread or 0.02
	if spread > 0 then
		dir = dir + VectorRand() * spread
		dir:Normalize()
	end
	local vel = dir * speed
	local g = def.Gravity or 0
	if g > 0 then vel.z = vel.z + 0.5 * g * (dist / speed) end -- lob so it comes down on the target

	nextId = (nextId + 1) % 65536
	local life = def.Life or 5
	local now = CurTime()
	local H = def.Homing
	local target = opts and opts.target
	list[#list + 1] = {
		id = nextId, pos = Vector(src.x, src.y, src.z), vel = vel, g = g,
		def = def, attacker = attacker, die = now + life,
		home = H, lit = H and now + (H.Delay or 0.3), target = IsValid(target) and target or nil,
		dst = Vector(dst.x, dst.y, dst.z),
	}

	net.Start("ngl_proj")
	net.WriteUInt(nextId, 16)
	net.WriteVector(src)
	net.WriteVector(vel)
	net.WriteFloat(g)
	net.WriteString(def.Model or "")
	net.WriteFloat(life)
	net.WriteBool(H ~= nil)
	if H then
		net.WriteFloat(H.Delay or 0.3)
		net.WriteFloat(H.Turn or 90)
		net.WriteFloat(H.Speed or 1500)
		net.WriteFloat(H.Accel or 2000)
		net.WriteVector(dst)
		net.WriteEntity(IsValid(target) and target or NULL)
		net.WriteBool(def.Trail == true)
	end
	net.SendPVS(src)
end

-- Turns velocity `vel` towards `goal` by at most `turn` degrees and moves
-- its speed towards `speed`. Shared idea with the client (cl_projectile.lua).
local function steer(vel, from, goal, turn, speed, accel, dt)
	local cur = vel:Length()
	local dir = vel / math.max(cur, 0.001)
	local want = goal - from
	want:Normalize()
	local cosA = math.Clamp(dir:Dot(want), -1, 1)
	local a = math.acos(cosA)
	local step = math.rad(turn) * dt
	if a > step and a > 1e-4 then
		local s = math.sin(a)
		dir = dir * (math.sin(a - step) / s) + want * (math.sin(step) / s)
	else
		dir = want
	end
	cur = cur < speed and math.min(speed, cur + accel * dt) or speed
	return dir * cur
end
Proj.Steer = steer

function Proj.Count() return #list end

hook.Add("Tick", "NGL.Proj", function()
	if #list == 0 then return end
	local t0 = SysTime()
	local dt = engine.TickInterval()
	local now = CurTime()

	local i = 1
	while i <= #list do
		local p = list[i]
		local vel = p.vel
		if p.g ~= 0 then vel.z = vel.z - p.g * dt end
		if p.home and now >= p.lit then
			local t = p.target
			local goal = (IsValid(t) and not t.NGLDying) and t:WorldSpaceCenter() or p.dst
			local H = p.home
			vel = steer(vel, p.pos, goal, H.Turn or 90, H.Speed or 1500, H.Accel or 2000, dt)
			p.vel = vel
		end
		local from = p.pos
		local to = from + vel * dt
		trace.start, trace.endpos = from, to
		trace.filter = IsValid(p.attacker) and p.attacker or nil
		util.TraceLine(trace)

		local done, at = false, to
		if result.Hit then
			at = result.HitPos
			land(p.def, p.attacker, at, result.Entity)
			done = true
		elseif now > p.die then
			done = true
		else
			p.pos = to
		end

		if done then
			net.Start("ngl_proj_end")
			net.WriteUInt(p.id, 16)
			net.SendPVS(at)
			list[i] = list[#list]
			list[#list] = nil
		else
			i = i + 1
		end
	end

	local B = NGL.Bench
	if B then B.LuaTime = B.LuaTime + (SysTime() - t0) end
end)
