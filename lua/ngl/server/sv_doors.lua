-- Doors: NPCs open closed doors in their way (ENT.OpenDoors). The ones with
-- ENT.DoorBreach (Combine, rebels) kick them in during a fight (an enemy, or
-- one seen in the last few seconds) and kick locked ones; otherwise they
-- open them normally too.
--
-- The map's doors go into a small grid once (and as they're created), so an
-- NPC's check costs a table lookup unless a door is right in front of it;
-- only then is anything traced or fired.
--
-- Zombies (ENT.DoorBreach = "always") never open doors: they beat on them
-- with their claws until they give way (ENT.DoorHits blows), in a fight or
-- not.
--
-- Doors are HL2's (prop_door_rotating, func_door, func_door_rotating) and
-- any other door: an entity whose class has "door" in it (addon and map
-- doors), a prop whose model has "door" in it, a class listed in
-- ngl_door_classes, or an entity with ent.NGLDoor = true (false: never a
-- door). Those other doors count as shut while they're solid and where they
-- were put, and only when one actually blocks the NPC's way.
--
-- ngl_door_breach 2: a kicked door flies off its hinges (a physics prop the
-- door's shape; the door comes back after ngl_door_respawn seconds, so the
-- map's own logic keeps working; a loose physics prop door is just knocked
-- flying). 1: kicked doors just burst open (other doors that don't open
-- are knocked down as with 2). 0: never kick, NPCs open doors like everyone
-- else (locked ones stop them).

NGL.Doors = NGL.Doors or {}
local D = NGL.Doors

local cvBreach = CreateConVar("ngl_door_breach", "2", FCVAR_ARCHIVE,
	"NGL NPCs that kick doors (Combine, rebels): 2 = off the hinges, 1 = burst open, 0 = just open them.", 0, 2)
local cvRespawn = CreateConVar("ngl_door_respawn", "120", FCVAR_ARCHIVE,
	"Seconds before a door kicked off its hinges is put back (0 = never).", 0, 3600)

local floor, IsValid, CurTime = math.floor, IsValid, CurTime
local CELL = 256
local REACH = 80        -- door this close ahead (2D, from its middle): deal with it
local CHECK_EVERY = 0.3

local cvClasses = CreateConVar("ngl_door_classes", "", FCVAR_ARCHIVE,
	"More entity classes NGL NPCs treat as doors (open or break), comma separated.")

local CLASSES = { prop_door_rotating = "prop", func_door_rotating = "brush", func_door = "brush" }
D.Classes = CLASSES
local PROPS = { prop_dynamic = true, prop_dynamic_override = true, prop_physics = true, prop_physics_multiplayer = true, prop_physics_override = true }

local extra = {}
local function readExtra()
	extra = {}
	for c in string.gmatch(cvClasses:GetString(), "[^,%s]+") do extra[c:lower()] = true end
end
readExtra()

-- What kind of door `e` is: "prop" / "brush" (HL2's), "custom" (any other
-- door), or nil (not a door).
function D.KindOf(e)
	if e.NGLDoor == false then return nil end
	local cls = e:GetClass()
	local k = CLASSES[cls]
	if k then return k end
	if e.NGLDoor or extra[cls] then return "custom" end
	if e:IsPlayer() or e:IsNPC() or e:IsNextBot() or e:IsWeapon() then return nil end
	if string.find(cls, "door", 1, true) and not string.find(cls, "trigger", 1, true) then return "custom" end
	if PROPS[cls] then
		local m = e:GetModel()
		if m and string.find(string.lower(m), "door", 1, true) then return "custom" end
	end
end

local cells = {}
local function key(x, y) return (floor(x / CELL) + 4096) * 8192 + (floor(y / CELL) + 4096) end

function D.Unregister(door)
	local k = door.NGLDoorCell
	if k and cells[k] then cells[k][door] = nil end
	door.NGLDoorCell = nil
end

-- Puts a door in the grid where it is now (a custom door counts as shut
-- while it's here).
function D.Register(door)
	if not IsValid(door) then return end
	local kind = D.KindOf(door)
	if not kind then return end
	if door.NGLDoorCell then D.Unregister(door) end
	local c = door:WorldSpaceCenter()
	local k = key(c.x, c.y)
	cells[k] = cells[k] or {}
	cells[k][door] = true
	door.NGLDoorCell = k
	door.NGLDoorPos = c
	door.NGLDoorKind = kind
	door.NGLDoorAng = door:GetAngles()
end

function D.Scan()
	cells = {}
	for _, e in ipairs(ents.GetAll()) do
		e.NGLDoorCell = nil
		D.Register(e)
	end
end

cvars.AddChangeCallback("ngl_door_classes", function() readExtra() D.Scan() end, "NGL.Doors")
hook.Add("InitPostEntity", "NGL.Doors", D.Scan)
hook.Add("PostCleanupMap", "NGL.Doors", D.Scan)
hook.Add("OnEntityCreated", "NGL.Doors", function(e)
	local cls = e:GetClass()
	if CLASSES[cls] or extra[cls] or PROPS[cls] or string.find(cls, "door", 1, true) or e.NGLDoor then
		timer.Simple(0, function() D.Register(e) end) -- after it's placed and has its model
	end
end)
-- A door someone moved (physgun, tool): shut where it was put down.
local function moved(_, e)
	if IsValid(e) and e.NGLDoorKind == "custom" and not e.NGLBroken then D.Register(e) end
end
hook.Add("PhysgunDrop", "NGL.Doors", moved)
hook.Add("OnPhysgunFreeze", "NGL.Doors", function(_, _, e) moved(nil, e) end)

-- Shut (prop doors: m_eDoorState 0; brush doors: at their start, m_toggle_state 1).
-- Other doors: shut while solid and where they were put (not swung or slid
-- away).
function D.IsClosed(door)
	if door.NGLBroken then return false end
	local kind = door.NGLDoorKind
	if kind == "prop" then
		return door:GetInternalVariable("m_eDoorState") == 0
	elseif kind == "brush" then
		return door:GetInternalVariable("m_toggle_state") == 1
	end
	if door:IsEffectActive(EF_NODRAW) or not door:IsSolid() then return false end
	local ts = door:GetInternalVariable("m_toggle_state") -- a door-like brush class
	if isnumber(ts) and door:GetInternalVariable("m_flMoveDistance") then return ts == 1 end
	local ds = door:GetInternalVariable("m_eDoorState") -- a prop_door_rotating subclass
	if isnumber(ds) then return ds == 0 end
	if door:WorldSpaceCenter():DistToSqr(door.NGLDoorPos) > 64 then return false end
	local a, b = door:GetAngles(), door.NGLDoorAng
	return math.abs(math.AngleDifference(a.y, b.y)) < 5 and math.abs(math.AngleDifference(a.p, b.p)) < 5
		and math.abs(math.AngleDifference(a.r, b.r)) < 5
end

-- Is this custom door really in the way (not a door on a wall beside the
-- path)? A trace from the NPC's middle toward the door hits it.
local tr = {}
local trOut = {}
tr.output = trOut
local function blocks(npc, door, pos)
	local c = door.NGLDoorPos
	tr.start = Vector(pos.x, pos.y, pos.z + 36)
	tr.endpos = Vector(c.x, c.y, math.Clamp(c.z, pos.z + 8, pos.z + 64))
	tr.filter = npc
	tr.mask = MASK_SOLID
	util.TraceLine(tr)
	return trOut.Entity == door
end

-- A closed door within REACH ahead of `pos` along (dx, dy), or nil.
function D.Ahead(pos, dx, dy, npc)
	local cx, cy = floor(pos.x / CELL), floor(pos.y / CELL)
	for x = cx - 1, cx + 1 do
		for y = cy - 1, cy + 1 do
			local c = cells[(x + 4096) * 8192 + (y + 4096)]
			if c then
				for door in pairs(c) do
					if not IsValid(door) then
						c[door] = nil
					else
						local p = door.NGLDoorPos
						local ox, oy = p.x - pos.x, p.y - pos.y
						if ox * ox + oy * oy < REACH * REACH and ox * dx + oy * dy > -8
							and math.abs(p.z - pos.z - 48) < 96 and D.IsClosed(door)
							and (door.NGLDoorKind ~= "custom" or not npc or blocks(npc, door, pos)) then
							return door
						end
					end
				end
			end
		end
	end
end

local function sound(door, snd, lvl)
	door:EmitSound(snd, lvl or 75, math.random(95, 105))
end

local function metal(door)
	local m = door:GetMaterialType()
	return m == MAT_METAL or m == MAT_GRATE or m == MAT_VENT
end
local function breakSound(door)
	if metal(door) then sound(door, "physics/metal/metal_box_break" .. math.random(2) .. ".wav", 85)
	else sound(door, "physics/wood/wood_furniture_break" .. math.random(2) .. ".wav", 85) end
end
local function hitSound(door)
	if metal(door) then sound(door, "physics/metal/metal_box_impact_hard" .. math.random(3) .. ".wav", 80)
	else sound(door, "physics/wood/wood_box_impact_hard" .. math.random(3) .. ".wav", 80) end
end

-- A custom door: its own Open input, or its Use (addon doors open on use).
local function openCustom(npc, door, delay)
	door:Fire("Open", "", delay, npc)
	if door.Use and door:IsScripted() then
		timer.Simple(delay, function()
			if IsValid(door) then pcall(door.Use, door, npc, npc, USE_ON, 1) end
		end)
	end
end

-- Opens it the normal way (away from the NPC for prop doors). False if locked.
function D.Open(npc, door)
	if door:GetInternalVariable("m_bLocked") then return false end
	local kind = door.NGLDoorKind
	if kind == "prop" then
		door:Fire("OpenAwayFrom", "!activator", 0, npc)
	elseif kind == "brush" then
		door:Fire("Open", "", 0, npc)
	else
		if door.NGLOpenTried and CurTime() < door.NGLOpenTried then return true end
		door.NGLOpenTried = CurTime() + 2
		openCustom(npc, door, 0)
	end
	return true
end

-- Out of the way for now: hidden and not solid, back after ngl_door_respawn.
local function takeAway(door)
	door.NGLBroken = true
	door:SetNoDraw(true)
	door:SetNotSolid(true)
	local t = cvRespawn:GetFloat()
	if t > 0 then
		timer.Simple(t, function()
			if not IsValid(door) then return end
			door.NGLBroken = nil
			door.NGLDoorHits = nil
			door:SetNoDraw(false)
			door:SetNotSolid(false)
		end)
	end
end

-- A copy of the door that flies off (studio models only; brushes have none).
local function flyingCopy(door, dir)
	local mdl = door:GetModel()
	if not mdl or mdl:sub(1, 1) == "*" or not util.IsValidProp(mdl) then return false end
	local prop = ents.Create("prop_physics")
	if not IsValid(prop) then return false end
	prop:SetModel(mdl)
	prop:SetSkin(door:GetSkin())
	prop:SetMaterial(door:GetMaterial())
	prop:SetColor(door:GetColor())
	prop:SetPos(door:GetPos())
	prop:SetAngles(door:GetAngles())
	prop:Spawn()
	prop:SetCollisionGroup(COLLISION_GROUP_DEBRIS) -- doesn't trip up NPCs or players
	local phys = prop:GetPhysicsObject()
	if IsValid(phys) then
		phys:Wake()
		phys:SetVelocity(dir * 450 + Vector(0, 0, 120))
		phys:AddAngleVelocity(Vector(math.Rand(-200, 200), math.Rand(-200, 200), math.Rand(-100, 100)))
	end
	local t = cvRespawn:GetFloat()
	SafeRemoveEntityDelayed(prop, t > 0 and t or 300)
	return true
end

-- A loose physics prop door: unfreeze it and knock it away.
local function knockLoose(door, dir)
	local phys = door:GetPhysicsObject()
	if door:GetClass():find("prop_physics", 1, true) and IsValid(phys) then
		phys:EnableMotion(true)
		phys:Wake()
		phys:SetVelocity(dir * 450 + Vector(0, 0, 120))
		phys:AddAngleVelocity(Vector(math.Rand(-200, 200), math.Rand(-200, 200), math.Rand(-100, 100)))
		return true
	end
	return false
end

-- The kick lands: off the hinges, or burst open.
function D.Breach(npc, door)
	if not IsValid(door) or door.NGLBroken then return end
	door.NGLKicking = nil
	door.NGLDoorHits = nil
	local mode = cvBreach:GetInt()
	local from = IsValid(npc) and npc:GetPos() or door:GetPos()
	local dir = door.NGLDoorPos - from
	dir.z = 0
	dir:Normalize()
	local kind = door.NGLDoorKind
	if kind == "custom" then
		door:Fire("Unlock", "", 0, npc)
		if knockLoose(door, dir) then
			breakSound(door)
			return
		end
		if mode >= 2 then
			flyingCopy(door, dir)
			takeAway(door)
			breakSound(door)
			return
		end
		-- Burst open if it opens at all; one that doesn't is knocked down.
		openCustom(npc, door, 0.01)
		hitSound(door)
		timer.Simple(0.5, function()
			if IsValid(door) and D.IsClosed(door) then
				takeAway(door)
				breakSound(door)
			end
		end)
	elseif mode >= 2 and kind == "prop" then
		flyingCopy(door, dir)
		-- Keep the door entity (map logic may use it), just gone for now.
		takeAway(door)
		breakSound(door)
	else
		door:Fire("Unlock", "", 0, npc)
		if kind == "prop" then
			door:Fire("OpenAwayFrom", "!activator", 0.01, npc)
		else
			door:Fire("Open", "", 0.01, npc)
		end
		hitSound(door)
	end
end

-- One blow of several (ENT.DoorHits): the door gives way on the last one.
-- Blows from different NPCs add up; a door left alone for HIT_FORGET
-- seconds is whole again.
local HIT_FORGET = 10
function D.Hit(npc, door)
	if not IsValid(door) or door.NGLBroken then return end
	door.NGLKicking = nil
	local now = CurTime()
	local need = IsValid(npc) and npc.DoorHits or 1
	local hits = (door.NGLDoorHits and now - (door.NGLDoorHitT or 0) < HIT_FORGET) and door.NGLDoorHits or 0
	hits = hits + 1
	door.NGLDoorHitT = now
	if hits >= need then
		D.Breach(npc, door)
	else
		door.NGLDoorHits = hits
		hitSound(door)
		util.ScreenShake(door.NGLDoorPos, 2, 10, 0.3, 300)
	end
end

-- Kick it: face it, the Kick animation (or a short shove without one), and
-- the door gives way part way through.
function D.Kick(npc, door, now)
	if door.NGLKicking and now < door.NGLKicking then return end
	local c = door.NGLDoorPos
	local p = npc:GetPos()
	npc:SetAngles(Angle(0, math.deg(math.atan2(c.y - p.y, c.x - p.x)), 0))
	-- The kick, or for those without one that beat on doors (zombies) a
	-- melee swing.
	local A = npc.NGLActs
	local dur = A and A.Kick and npc:PlayAnim(A.Kick, true)
	local hit
	if not dur and npc.DoorBreach == "always" and npc.Melee and npc.NGLPlayMeleeAnim and not npc.Melee.Gesture then
		local seq
		dur, seq = npc:NGLPlayMeleeAnim()
		local t = dur and npc.NGLHitTimes and npc:NGLHitTimes(seq, dur)
		hit = t and t[1] -- on the claw's frame
	end
	if not dur then
		dur = 0.6
		NGL.Core.StopMoving(npc)
		npc.NGLBusyUntil = math.max(npc.NGLBusyUntil or 0, now + dur)
	end
	hit = hit or math.min(dur * 0.45, 0.6)
	door.NGLKicking = now + hit + 1
	timer.Simple(hit, function() D.Hit(npc, door) end)
end

-- From the core think, for moving NPCs that open or kick doors.
function D.Think(npc, now, pos)
	if now < (npc.NGLNextDoor or 0) or npc.NGLAnimUntil then return end
	npc.NGLNextDoor = now + CHECK_EVERY
	local g = npc.NGLSteer
	if not g then return end
	local dx, dy = g.x - pos.x, g.y - pos.y
	local l = math.sqrt(dx * dx + dy * dy)
	if l < 1 then return end
	local door = D.Ahead(pos, dx / l, dy / l, npc)
	if not door then return end
	-- Kickers only kick in a fight (an enemy, or one seen in the last few
	-- seconds), or when it's locked; otherwise they open it like anyone.
	-- Zombies ("always") always beat it down.
	local breach = npc.DoorBreach and cvBreach:GetInt() > 0
	if breach and (npc.DoorBreach == "always" or D.InFight(npc, now) or door:GetInternalVariable("m_bLocked")) then
		D.Kick(npc, door, now)
	elseif npc.OpenDoors or npc.DoorBreach then
		D.Open(npc, door) -- locked: it stays shut, and the stuck check sends the NPC another way
	end
end

local FIGHT_MEMORY = 8
function D.InFight(npc, now)
	return npc.NGLEnemy ~= nil or now - (npc.NGLLastSeenT or -1000) < FIGHT_MEMORY
end

if game.GetWorld and IsValid(game.GetWorld()) then D.Scan() end
