-- Doors: NPCs open closed doors in their way (ENT.OpenDoors), and the ones
-- with ENT.DoorBreach (Combine, rebels) kick them in, locked ones too.
--
-- The map's doors go into a small grid once (and as they're created), so an
-- NPC's check costs a table lookup unless a door is right in front of it;
-- only then is anything traced or fired.
--
-- ngl_door_breach 2: a kicked door flies off its hinges (a physics prop the
-- door's shape; the door comes back after ngl_door_respawn seconds, so the
-- map's own logic keeps working). 1: kicked doors just burst open. 0: never
-- kick, NPCs open doors like everyone else (locked ones stop them).

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

local CLASSES = { prop_door_rotating = "prop", func_door_rotating = "brush", func_door = "brush" }
D.Classes = CLASSES

local cells = {}
local function key(x, y) return (floor(x / CELL) + 4096) * 8192 + (floor(y / CELL) + 4096) end

function D.Register(door)
	if not IsValid(door) or door.NGLDoorCell then return end
	local c = door:WorldSpaceCenter()
	local k = key(c.x, c.y)
	cells[k] = cells[k] or {}
	cells[k][door] = true
	door.NGLDoorCell = k
	door.NGLDoorPos = c
end

function D.Scan()
	cells = {}
	for cls in pairs(CLASSES) do
		for _, e in ipairs(ents.FindByClass(cls)) do
			e.NGLDoorCell = nil
			D.Register(e)
		end
	end
end

hook.Add("InitPostEntity", "NGL.Doors", D.Scan)
hook.Add("PostCleanupMap", "NGL.Doors", D.Scan)
hook.Add("OnEntityCreated", "NGL.Doors", function(e)
	if CLASSES[e:GetClass()] then
		timer.Simple(0, function() D.Register(e) end)
	end
end)

-- Shut (prop doors: m_eDoorState 0; brush doors: at their start, m_toggle_state 1).
function D.IsClosed(door)
	if door.NGLBroken then return false end
	local kind = CLASSES[door:GetClass()]
	if kind == "prop" then
		return door:GetInternalVariable("m_eDoorState") == 0
	end
	return door:GetInternalVariable("m_toggle_state") == 1
end

-- A closed door within REACH ahead of `pos` along (dx, dy), or nil.
function D.Ahead(pos, dx, dy)
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
							and math.abs(p.z - pos.z - 48) < 96 and D.IsClosed(door) then
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

-- Opens it the normal way (away from the NPC for prop doors). False if locked.
function D.Open(npc, door)
	if door:GetInternalVariable("m_bLocked") then return false end
	if CLASSES[door:GetClass()] == "prop" then
		door:Fire("OpenAwayFrom", "!activator", 0, npc)
	else
		door:Fire("Open", "", 0, npc)
	end
	return true
end

-- The kick lands: off the hinges, or burst open.
function D.Breach(npc, door)
	if not IsValid(door) or door.NGLBroken then return end
	door.NGLKicking = nil
	local mode = cvBreach:GetInt()
	local from = IsValid(npc) and npc:GetPos() or door:GetPos()
	local dir = door.NGLDoorPos - from
	dir.z = 0
	dir:Normalize()
	if mode >= 2 and CLASSES[door:GetClass()] == "prop" then
		local prop = ents.Create("prop_physics")
		if IsValid(prop) then
			prop:SetModel(door:GetModel())
			prop:SetSkin(door:GetSkin())
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
		end
		-- Keep the door entity (map logic may use it), just gone for now.
		door.NGLBroken = true
		door:SetNoDraw(true)
		door:SetNotSolid(true)
		sound(door, "physics/wood/wood_furniture_break" .. math.random(2) .. ".wav", 85)
		local t = cvRespawn:GetFloat()
		if t > 0 then
			timer.Simple(t, function()
				if not IsValid(door) then return end
				door.NGLBroken = nil
				door:SetNoDraw(false)
				door:SetNotSolid(false)
			end)
		end
	else
		door:Fire("Unlock", "", 0, npc)
		if CLASSES[door:GetClass()] == "prop" then
			door:Fire("OpenAwayFrom", "!activator", 0.01, npc)
		else
			door:Fire("Open", "", 0.01, npc)
		end
		sound(door, "physics/wood/wood_box_impact_hard" .. math.random(3) .. ".wav", 80)
	end
end

-- Kick it: face it, the Kick animation (or a short shove without one), and
-- the door gives way part way through.
function D.Kick(npc, door, now)
	if door.NGLKicking and now < door.NGLKicking then return end
	local c = door.NGLDoorPos
	local p = npc:GetPos()
	npc:SetAngles(Angle(0, math.deg(math.atan2(c.y - p.y, c.x - p.x)), 0))
	local dur = npc.NGLActs and npc.NGLActs.Kick and npc:PlayAnim(npc.NGLActs.Kick, true)
	if not dur then
		dur = 0.6
		NGL.Core.StopMoving(npc)
		npc.NGLBusyUntil = math.max(npc.NGLBusyUntil or 0, now + dur)
	end
	local hit = math.min(dur * 0.45, 0.6)
	door.NGLKicking = now + hit + 1
	timer.Simple(hit, function() D.Breach(npc, door) end)
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
	local door = D.Ahead(pos, dx / l, dy / l)
	if not door then return end
	if npc.DoorBreach and cvBreach:GetInt() > 0 then
		D.Kick(npc, door, now)
	elseif npc.OpenDoors then
		D.Open(npc, door) -- locked: it stays shut, and the stuck check sends the NPC another way
	end
end

if game.GetWorld and IsValid(game.GetWorld()) then D.Scan() end
