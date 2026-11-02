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
function Proj.Fire(attacker, def, src, dst, visual)
	if not visual then
		if math.random() < (def.Accuracy or 0.6) then
			trace.start, trace.endpos, trace.filter = src, dst, attacker
			util.TraceLine(trace)
			land(def, attacker, result.HitPos, result.Entity)
		end
		return
	end

	local speed = def.Speed or 1500
	local dir = dst - src
	local dist = dir:Length()
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
	list[#list + 1] = {
		id = nextId, pos = Vector(src.x, src.y, src.z), vel = vel, g = g,
		def = def, attacker = attacker, die = CurTime() + life,
	}

	net.Start("ngl_proj")
	net.WriteUInt(nextId, 16)
	net.WriteVector(src)
	net.WriteVector(vel)
	net.WriteFloat(g)
	net.WriteString(def.Model or "")
	net.WriteFloat(life)
	net.SendPVS(src)
end

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
