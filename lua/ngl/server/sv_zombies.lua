-- NGL zombies and their headcrabs.
--
-- A zombie with ENT.Headcrab drops a live headcrab of that class when it
-- dies, like in HL2: not when the killing blow hit the head (the crab dies
-- with it) or blew it up. The crab bodygroup (ENT.HeadcrabBodygroup) is
-- taken off the body so the ragdoll is bare. The poison zombie also throws
-- the crabs it carries on its back (ngl_zombie_poison.lua) through
-- Zombie.SpawnCrab.
--
-- A battle of 200 zombies would make 200 more NPCs as they die, so the crabs
-- alive at once that came off zombies are capped (ngl_headcrab_max); over
-- the cap no crab comes off.

NGL.Zombie = NGL.Zombie or {}
local Z = NGL.Zombie

local cvCrabs = CreateConVar("ngl_zombie_headcrabs", "1", FCVAR_ARCHIVE,
	"NGL zombies drop a live headcrab when they die (and poison zombies throw theirs). 0 = never.", 0, 1)
local cvMax = CreateConVar("ngl_headcrab_max", "60", FCVAR_ARCHIVE,
	"Most headcrabs from NGL zombies alive at once; over this no more come off.", 0, 1000)

Z.Live = Z.Live or {}

function Z.CrabCount()
	local n = 0
	for e in pairs(Z.Live) do
		if IsValid(e) and not e.NGLDying then n = n + 1 else Z.Live[e] = nil end
	end
	return n
end

function Z.CanSpawnCrab()
	return cvCrabs:GetBool() and Z.CrabCount() < cvMax:GetInt()
end

-- Shows or hides the crab riding on a zombie's head.
function Z.ShowCrab(npc, on)
	local bg = npc.HeadcrabBodygroup
	if bg and bg < npc:GetNumBodyGroups() then npc:SetBodygroup(bg, on and 1 or 0) end
end

-- A headcrab of `class` at `pos`, after `enemy`. opts.throwTo: thrown from
-- `pos` to land there, opts.time seconds in the air (it lands and goes for
-- the enemy); opts.leap = false: waits a second before its first leap.
-- Returns the crab, or nil over the cap.
function Z.SpawnCrab(class, pos, yaw, enemy, opts)
	if not Z.CanSpawnCrab() then return nil end
	local crab = ents.Create(class)
	if not IsValid(crab) then return nil end
	crab:SetPos(pos)
	crab:SetAngles(Angle(0, yaw or 0, 0))
	crab:Spawn()
	crab:Activate()
	Z.Live[crab] = true
	opts = opts or {}
	-- Next tick, once its locomotion is running.
	timer.Simple(0, function()
		if not IsValid(crab) or crab.NGLDying then return end
		local now = CurTime()
		if IsValid(enemy) and NGL.Core.IsHostile(crab, enemy) then NGL.Core.SetEnemy(crab, enemy) end
		if opts.throwTo then
			local v = NGL.Leap.Ballistic(crab:GetPos(), opts.throwTo, crab.loco:GetGravity(), opts.time or 1)
			NGL.Leap.Start(crab, IsValid(enemy) and enemy or opts.throwTo, crab.LeapAttack, now, { vel = v })
		elseif opts.leap == false then
			crab.NGLNextLeap = now + 1
		end
	end)
	return crab
end

-- The crab comes off a dying zombie (ENT:OnKilled).
local HEAD_BAND = 14 -- damage this close to the top of the head is a head shot
function Z.OnKilled(npc, dmginfo)
	if not npc.Headcrab then return end
	if dmginfo:IsDamageType(DMG_BLAST) or dmginfo:IsDamageType(DMG_DISSOLVE) then return end
	local pos = npc:GetPos()
	local hp = dmginfo:GetDamagePosition()
	local top = pos.z + (npc.EyeHeight or 60) + 6
	if hp and hp ~= vector_origin and hp.z > top - HEAD_BAND and hp:Distance2DSqr(pos) < 40 * 40 then
		return -- shot in the head: the crab died too (it stays on the body)
	end
	local crab = Z.SpawnCrab(npc.Headcrab, Vector(pos.x, pos.y, pos.z + (npc.EyeHeight or 60) - 8),
		npc:GetAngles().y, npc.NGLEnemy, { leap = false })
	if crab then Z.ShowCrab(npc, false) end
end
