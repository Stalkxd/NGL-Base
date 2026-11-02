-- NGL reinforcements: a squad leader that is down to a few men (ENT.Squad
-- with Reinforce) calls more. On maps with open sky a dropship brings them
-- (sv_air.lua, ngl_dropship); indoors, where it can't land near the leader,
-- and on maps without sky, they arrive on foot from a spot neither the
-- enemy nor any player can see.
--
--   ENT.Squad.Reinforce = {
--   	Ship = "ngl_dropship", Cargo = "ngl_combine_soldier",
--   	Count = 6,            -- soldiers per dropship
--   	OnFootCount = 4,      -- soldiers per wave on foot
--   	When = 3,             -- call when this many members or fewer are left
--   	Vehicle = "ngl_apc",  -- optional: a dropship can bring this instead
--   	VehicleLimit = 1,     -- vehicles per leader
--   	VehicleThreat = 4,    -- enemies near the target that call for a vehicle
--   	ChooseVehicle = nil,  -- optional function(leader, squad, enemy) -> true
--   }
--
-- A wave is a vehicle when the leader has no vehicle of its own left and the
-- fight is heavy: the target is a player or a vehicle, or VehicleThreat or
-- more enemies stand near it. Otherwise soldiers. With no open sky the
-- vehicle drives in from out of sight, like the soldiers walk in.

NGL.Reinforce = NGL.Reinforce or {}
local R = NGL.Reinforce
R.Active = R.Active or {} -- [ship] = true

local cvLimit = CreateConVar("ngl_reinforce_limit", "3", FCVAR_ARCHIVE,
	"Reinforcement waves (dropship or on foot) each NGL squad leader may call. 0 = none, -1 = unlimited.", -1, 1000)
local cvCooldown = CreateConVar("ngl_reinforce_cooldown", "90", FCVAR_ARCHIVE,
	"Seconds between reinforcement waves of one NGL squad leader.", 0, 3600)
local cvShips = CreateConVar("ngl_dropship_max", "2", FCVAR_ARCHIVE,
	"NGL dropships in the air at once, across the map.", 0, 32)
local cvVehicle = CreateConVar("ngl_reinforce_apc", "1", FCVAR_ARCHIVE,
	"1 = NGL squad leaders may get an APC (Reinforce.Vehicle) as a reinforcement wave.", 0, 1)

local IsValid = IsValid

function R.CountShips()
	local n = 0
	for ship in pairs(R.Active) do
		if IsValid(ship) then n = n + 1 else R.Active[ship] = nil end
	end
	return n
end

-- Creates one NPC of `class` at `pos` and puts it in the leader's squad.
function R.Spawn(class, pos, leader, sq, yaw)
	local e = ents.Create(class)
	if not IsValid(e) then return nil end
	e:SetPos(pos)
	e:SetAngles(Angle(0, yaw or 0, 0))
	e:Spawn()
	e:Activate()
	if sq and not sq:IsFull() then sq:Add(e) end
	if IsValid(leader) then e.NGLHome = leader:GetPos() end
	return e
end

-- A delivered vehicle takes the leader's orders (a squad asset, not a member).
function R.AttachVehicle(v, leader, sq)
	if not (IsValid(v) and IsValid(leader) and not leader.NGLDying and sq) then return end
	v.NGLCommander = leader
	sq.assets[v] = true
end

-- Should this wave be a vehicle (its class) instead of soldiers (nil)?
function R.WantsVehicle(npc, sq, enemy, rc)
	local class = rc.Vehicle
	if not class or not cvVehicle:GetBool() then return nil end
	if (npc.NGLVehiclesCalled or 0) >= (rc.VehicleLimit or 1) then return nil end
	for v in pairs(sq.assets) do
		if IsValid(v) and not v.NGLDying then return nil end -- still has one
	end
	if rc.ChooseVehicle then return rc.ChooseVehicle(npc, sq, enemy) and class or nil end
	if enemy:IsPlayer() or enemy.IsVehicleNPC then return class end
	local near = NGL.FindInRadius(enemy:GetPos(), 800, function(e) return NGL.Core.IsHostile(npc, e) end)
	return #near >= (rc.VehicleThreat or 4) and class or nil
end

-- Is `pos` in sight of `ent` (an enemy or a player)?
local losTrace = { mask = MASK_SOLID_BRUSHONLY }
local losResult = {}
losTrace.output = losResult
local function seenBy(ent, pos)
	losTrace.start = ent:EyePos()
	losTrace.endpos = pos + Vector(0, 0, 48)
	util.TraceLine(losTrace)
	return not losResult.Hit
end
R.SeenBy = seenBy

-- On foot: a grid point 1200 to 2500 units from the leader, away from the
-- enemy, that neither the enemy nor any player can see. A vehicle drives in
-- from such a point if it is wide enough.
function R.OnFoot(npc, sq, enemy, rc, vehicle)
	local Nav = NGL.Nav
	if not (Nav and Nav.Loaded) then return false end
	local pos, ePos = npc:GetPos(), enemy:GetPos()
	local away = pos - ePos
	local base = math.atan2(away.y, away.x)
	local players = player.GetAll()
	for try = 0, 9 do
		local a = base + ((try % 2 == 0) and 1 or -1) * math.floor((try + 1) / 2) * 0.5
		local dist = 1200 + 300 * (try % 5)
		local g = Nav.Nearest(Vector(pos.x + math.cos(a) * dist, pos.y + math.sin(a) * dist, pos.z))
		local width = vehicle and (scripted_ents.Get(vehicle) or {}).NavWidth
		if g and width and width > 24 and not Nav.WideOk(g, math.ceil(width / 8) * 8) then g = nil end
		if g then
			local gp = Nav.NodePos(g)
			local hidden = not seenBy(enemy, gp)
			for _, ply in ipairs(players) do
				if hidden and ply:Alive() and seenBy(ply, gp) then hidden = false end
			end
			if hidden and vehicle then
				local v = R.Spawn(vehicle, gp + Vector(0, 0, 8), npc, nil, math.deg(base) + 180)
				if not IsValid(v) then return false end
				R.AttachVehicle(v, npc, sq)
				if v.MoveTo then v:MoveTo(pos, true) end
				return true
			elseif hidden then
				local n = rc.OnFootCount or 4
				for k = 1, n do
					local ang = k / n * 2 * math.pi
					local e = R.Spawn(rc.Cargo, gp + Vector(math.cos(ang) * 60, math.sin(ang) * 60, 8), npc, sq)
					if IsValid(e) and e.MoveTo then e:MoveTo(pos, true) end
				end
				return true
			end
		end
	end
	return false
end

-- Tries to get reinforcements to the leader now. True if they're coming.
-- Under a roof (no sky straight above the leader)?
local upTrace = { mask = MASK_SOLID_BRUSHONLY }
local upResult = {}
upTrace.output = upResult
function R.Indoors(npc)
	local p = npc:GetPos()
	upTrace.start = p + Vector(0, 0, 64)
	upTrace.endpos = p + Vector(0, 0, 3000)
	util.TraceLine(upTrace)
	return upResult.Hit and not upResult.HitSky
end

-- `vehicle` = class to bring instead of soldiers. The dropship comes when
-- there is open sky and a place to land near the leader; indoors, in
-- narrow streets and on maps with no sky they come on foot instead.
function R.Call(npc, sq, enemy, now, rc, vehicle)
	local Air = NGL.Air
	if not (Air and Air.Ready) then return false end -- still building: try later
	if Air.Count == 0 or R.Indoors(npc) then return R.OnFoot(npc, sq, enemy, rc, vehicle) end

	if R.CountShips() >= cvShips:GetInt() then return false end
	local ePos = enemy:GetPos()
	local ground, top = Air.FindLanding(npc:GetPos(), ePos, rc.ShipRadius)
	local entry = ground and Air.EntryPoint(top, ePos)
	if not entry then return R.OnFoot(npc, sq, enemy, rc, vehicle) end -- nowhere to land nearby
	local ship = ents.Create(rc.Ship or "ngl_dropship")
	if not IsValid(ship) then return false end
	ship:SetPos(entry)
	ship:Spawn()
	ship:Activate()
	R.Active[ship] = true
	ship:NGLStartTrip({
		entry = entry, landing = ground, hover = top, enemyPos = ePos,
		leader = npc, squad = sq, cargo = rc.Cargo,
		count = vehicle and 0 or rc.Count or 6, vehicle = vehicle,
	})
	return true
end

-- From the leader's think (twice a second).
function R.Think(npc, now, sq, cfg)
	local rc = cfg.Reinforce
	if not rc or now < (npc.NGLNextReinforce or 0) then return end
	local limit = cvLimit:GetInt()
	if limit == 0 or (limit > 0 and (npc.NGLReinforced or 0) >= limit) then return end
	if sq:Count() - 1 > (rc.When or 3) then return end
	local e = npc.NGLEnemy
	if not IsValid(e) or now - (npc.NGLLastSeenT or -1e9) > 30 then return end

	npc.NGLNextReinforce = now + 15 -- no luck: ask again a bit later
	local vehicle = R.WantsVehicle(npc, sq, e, rc)
	local ok = R.Call(npc, sq, e, now, rc, vehicle)
	if not ok and vehicle then -- no way to bring it: soldiers instead
		vehicle = nil
		ok = R.Call(npc, sq, e, now, rc)
	end
	if ok then
		npc.NGLReinforced = (npc.NGLReinforced or 0) + 1
		if vehicle then npc.NGLVehiclesCalled = (npc.NGLVehiclesCalled or 0) + 1 end
		npc.NGLNextReinforce = now + cvCooldown:GetFloat()
		if npc.NGLSignal then npc:NGLSignal("Reinforce") end
		npc:NGLSound("Reinforce", true)
		return true
	end
end
