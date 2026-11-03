-- NGL spawning across the map, for testing big battles.
--
--   ngl_spawn_all <class[,class2,...]> [count] [spacing]
--     `count` NPCs (default 100) spread over the whole nav grid, on random
--     grid points at least `spacing` units apart (default 200), never
--     within 400 units of a player. Several classes: each NPC is one of
--     them at random, e.g. ngl_spawn_all ngl_zombie,ngl_zombie_fast 200.
--     Any NPC class works (NGL ones, npc_* ones); they come in a few per
--     tick, so a big spawn doesn't freeze the server.
--   ngl_spawn_clear [class|all]
--     Removes the NPCs ngl_spawn_all made (only that class with one given),
--     or every NGL NPC with "all".
--
-- Superadmins (or the server console). Picking spots is table reads plus
-- one hull trace per spot.

NGL.Spawner = NGL.Spawner or {}
local SP = NGL.Spawner
SP.Spawned = SP.Spawned or {}

local MAX_COUNT = 2000
local PER_TICK = 6
local PLAYER_CLEAR = 400

local standTrace = { mask = MASK_NPCSOLID, mins = Vector(-16, -16, 0), maxs = Vector(16, 16, 60), output = {} }

local function allowed(ply) return not IsValid(ply) or ply:IsSuperAdmin() end
local function tell(ply, msg)
	msg = "[NGL] " .. msg
	print(msg)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTTALK, msg) end
end

-- A class name from the NPC list (its key or its Class) or an entity class.
local function resolveClass(name)
	local npcs = list.Get("NPC")
	local e = npcs[name]
	if e and e.Class then return e.Class, e end
	if scripted_ents.Get(name) then return name end
	if string.StartWith(name, "npc_") then return name end
	return nil
end

-- Up to `count` random grid points, `spacing` apart, away from players.
local function pickSpots(count, spacing)
	local Nav = NGL.Nav
	local n = Nav.Count
	local dead = Nav.Dead or {}
	local players = {}
	for _, ply in ipairs(player.GetAll()) do players[#players + 1] = ply:GetPos() end
	local cell = math.max(spacing, 32)
	local taken = {}
	local function key(x, y) return math.floor(x / cell) .. ":" .. math.floor(y / cell) end
	local function free(p)
		local cx, cy = math.floor(p.x / cell), math.floor(p.y / cell)
		for x = cx - 1, cx + 1 do
			for y = cy - 1, cy + 1 do
				local list = taken[x .. ":" .. y]
				if list then
					for _, q in ipairs(list) do
						if q:DistToSqr(p) < spacing * spacing then return false end
					end
				end
			end
		end
		return true
	end
	local spots = {}
	local tries = 0
	while #spots < count and tries < count * 30 do
		tries = tries + 1
		local i = math.random(n)
		if not dead[i] then
			local p = Nav.NodePos(i)
			local ok = free(p)
			if ok then
				for _, q in ipairs(players) do
					if q:DistToSqr(p) < PLAYER_CLEAR * PLAYER_CLEAR then ok = false break end
				end
			end
			if ok then
				-- Nothing standing there (props, other NPCs).
				standTrace.start = Vector(p.x, p.y, p.z + 12)
				standTrace.endpos = standTrace.start
				local tr = util.TraceHull(standTrace)
				if not tr.Hit and not tr.StartSolid then
					spots[#spots + 1] = p
					local k = key(p.x, p.y)
					taken[k] = taken[k] or {}
					table.insert(taken[k], p)
				end
			end
		end
	end
	return spots
end

local queue = {}

local function spawnNext()
	for _ = 1, PER_TICK do
		local job = table.remove(queue, 1)
		if not job then
			hook.Remove("Tick", "NGL.Spawner")
			return
		end
		local e = ents.Create(job.class)
		if IsValid(e) then
			e:SetPos(job.pos + Vector(0, 0, 4))
			e:SetAngles(Angle(0, math.random(0, 359), 0))
			if job.info and job.info.KeyValues then
				for k, v in pairs(job.info.KeyValues) do e:SetKeyValue(k, v) end
			end
			if job.info and job.info.Weapons and #job.info.Weapons > 0 then
				e:SetKeyValue("additionalequipment", job.info.Weapons[math.random(#job.info.Weapons)])
			end
			e:Spawn()
			e:Activate()
			SP.Spawned[e] = job.class
			if IsValid(job.ply) and cleanup then cleanup.Add(job.ply, "npcs", e) end
		end
		if job.last then tell(job.ply, string.format("Spawned %d NPCs across the map.", job.total)) end
	end
end

concommand.Add("ngl_spawn_all", function(ply, _, args)
	if not allowed(ply) then return end
	local Nav = NGL.Nav
	if not (Nav and Nav.Loaded and Nav.Count > 0) then
		return tell(ply, "No nav grid on this map yet: run ngl_nav_generate first.")
	end
	if not args[1] then
		return tell(ply, "Usage: ngl_spawn_all <class[,class2,...]> [count] [spacing], e.g. ngl_spawn_all ngl_zombie,ngl_zombie_fast 200")
	end
	local classes = {}
	for name in string.gmatch(args[1], "[^,]+") do
		local class, info = resolveClass(string.Trim(name))
		if not class then return tell(ply, "Unknown NPC class: " .. name) end
		classes[#classes + 1] = { class = class, info = info }
	end
	local count = math.Clamp(math.floor(tonumber(args[2] or "") or 100), 1, MAX_COUNT)
	local spacing = math.Clamp(tonumber(args[3] or "") or 200, 32, 5000)
	local spots = pickSpots(count, spacing)
	if #spots == 0 then return tell(ply, "Found no free spots on the grid (try a smaller spacing).") end
	for k, p in ipairs(spots) do
		local c = classes[math.random(#classes)]
		queue[#queue + 1] = { class = c.class, info = c.info, pos = p, ply = ply, last = k == #spots, total = #spots }
	end
	hook.Add("Tick", "NGL.Spawner", spawnNext)
	tell(ply, string.format("Spawning %d NPCs over the nav grid%s...", #spots,
		#spots < count and string.format(" (only %d free spots at %d spacing)", #spots, spacing) or ""))
end)

concommand.Add("ngl_spawn_clear", function(ply, _, args)
	if not allowed(ply) then return end
	local which = args[1]
	local n = 0
	for k in pairs(queue) do queue[k] = nil end
	if which == "all" then
		for _, e in ipairs(ents.GetAll()) do
			if e.IsNGLNPC then e:Remove() n = n + 1 end
		end
		SP.Spawned = {}
	else
		local class = which and (resolveClass(which) or which)
		for e, c in pairs(SP.Spawned) do
			if not IsValid(e) then
				SP.Spawned[e] = nil
			elseif not class or c == class then
				e:Remove()
				SP.Spawned[e] = nil
				n = n + 1
			end
		end
	end
	tell(ply, string.format("Removed %d NPCs.", n))
end)
