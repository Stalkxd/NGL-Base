-- NGL nav: climb links at high walls, made on their own.
--
-- For NPCs that climb (ENT.Climb: fast zombies). When the grid is made
-- (ngl_nav_generate), every point at the foot of a wall looks at the wall
-- in front of it, along the four grid lines. Only a real wall gets a climb
-- link: something solid and steep right in front, still there above jump
-- height (lower ledges are jumped onto, see ngl_nav_max_up), no taller than
-- ngl_nav_max_climb, with no ceiling in the way going up and room for a
-- person to stand on top. Open ledges, railings and balconies get none: a
-- fast zombie climbs walls, not the air.
--
-- Tops of walls that the walking grid never reached (roofs, the tops of
-- crates and walls nobody can walk onto) get a grid of their own there,
-- flood-filled from the top of the climb, so climbers can get up and fight
-- from there. They come down by jumping (drop links) or the same climb.
--
-- Climb links go both ways and are saved with the grid. Maps whose grid
-- was made before this: `ngl_nav_climbs` adds them to the saved grid
-- without making it again (edits are kept apart, as always).
--
-- Cost: only while making the grid, a few traces per point at a wall
-- (about one in ten on most maps), within the generator's time budget.

local Nav = NGL.Nav
local I = Nav._I
local floor, abs, max, min = math.floor, math.abs, math.max, math.min

local cvMaxClimb = CreateConVar("ngl_nav_max_climb", "384", FCVAR_ARCHIVE,
	"Highest wall (units) ngl_nav_generate puts climb links on, for NPCs that climb (fast zombies). 0 = no climb links.", 0, 2000)

local STEP = 18
local HULL_MINS, HULL_MAXS = Vector(-13, -13, 0), Vector(13, 13, 72 - STEP)
local STEEP = 0.3        -- a wall's face: normal no steeper than this off level
local OVER = 24          -- how far past the wall's face the top is looked for
local MAX_ROUNDS = 3     -- climbs from tops found in a round are looked for again this often

-- Cardinal grid directions, same order as sv_nav.lua's DIRS (bits 1..4).
local CDIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local lineTrace = { mask = MASK_NPCSOLID_BRUSHONLY, output = {} }
local hullTrace = { mask = MASK_NPCSOLID_BRUSHONLY, mins = HULL_MINS, maxs = HULL_MAXS, output = {} }

local function setFilter()
	local list = {}
	for _, cls in ipairs({ "prop_door_rotating", "func_door", "func_door_rotating" }) do
		for _, e in ipairs(ents.FindByClass(cls)) do list[#list + 1] = e end
	end
	lineTrace.filter, hullTrace.filter = list, list
end

-- A steep face within `reach` straight ahead at height z: its distance, or nil.
local function wallAhead(x, y, z, dx, dy, reach)
	lineTrace.start = Vector(x, y, z)
	lineTrace.endpos = Vector(x + dx * reach, y + dy * reach, z)
	local tr = util.TraceLine(lineTrace)
	if tr.StartSolid or not tr.Hit or abs(tr.HitNormal.z) > STEEP then return nil end
	return tr.Fraction * reach
end

local function hullClear(ax, ay, az, bx, by, bz)
	hullTrace.start = Vector(ax, ay, az)
	hullTrace.endpos = Vector(bx, by, bz)
	local tr = util.TraceHull(hullTrace)
	return not tr.Hit and not tr.StartSolid, tr
end

-- Does node i already have a way onto a point near height z in direction d
-- (a walk bit, or a link)? Then it needs no climb there.
local function hasWay(i, d, j)
	if bit.band(Nav.NM[i], bit.lshift(1, d - 1)) ~= 0 then return true end
	if j then
		for _, L in ipairs(Nav.Links) do
			if L.a == i and L.b == j then return true end
		end
	end
	return false
end

-- The top of the wall in front of node i going in direction d, or nil:
-- returns its height and where to stand on it.
local function wallTop(i, d, maxUp, maxClimb)
	local S = Nav.S
	local p = Nav.NodePos(i)
	local dx, dy = CDIRS[d][1], CDIRS[d][2]
	-- A wall right in front (within a square), low down and above jump height.
	local face = wallAhead(p.x, p.y, p.z + STEP + 8, dx, dy, S)
	if not face then return nil end
	local face2 = wallAhead(p.x, p.y, p.z + maxUp + 16, dx, dy, S)
	if not face2 or abs(face2 - face) > 24 then return nil end -- leans back or steps: not one wall
	-- Room to go up at the wall's foot: no ceiling or overhang lower than the top.
	local fx, fy = p.x + dx * max(face - 14, 0), p.y + dy * max(face - 14, 0)
	local ok, tr = hullClear(fx, fy, p.z + STEP, fx, fy, p.z + STEP + maxClimb)
	local headroom = ok and (p.z + STEP + maxClimb) or tr.HitPos.z
	if tr.StartSolid then return nil end
	-- The top: ground just past the face, between jump height and headroom.
	local bx, by = p.x + dx * (face + OVER), p.y + dy * (face + OVER)
	local gz = I.groundAt(bx, by, headroom, p.z + maxUp + 1)
	if not gz or gz + STEP > headroom + 1 or gz - p.z > maxClimb then return nil end
	-- Over the top onto it, and standing room there.
	if not hullClear(fx, fy, gz + STEP + 2, bx, by, gz + STEP + 2) then return nil end
	return gz, bx, by
end

-- One pass over nodes first..last: climb links at every high wall, new tops
-- added to `queue`. Yields every `budget` seconds when given one.
local function scan(first, last, queue, maxUp, maxClimb, maxNodes, budget)
	local S = Nav.S
	local made = 0
	local t0 = SysTime()
	local dead = Nav.Dead
	for i = first, last do
		if not (dead and dead[i]) then
			for d = 1, 4 do
				-- A walk link that way: open ground, no wall.
				if bit.band(Nav.NM[i], bit.lshift(1, d - 1)) == 0 then
					local gz, bx, by = wallTop(i, d, maxUp, maxClimb)
					if gz then
						local cx, cy = floor(bx / S + 0.5), floor(by / S + 0.5)
						local j = I.nodeAt(cx, cy, gz, 32)
						if not j and Nav.Count < maxNodes then
							local ox, oy = floor(bx - cx * S + 0.5), floor(by - cy * S + 0.5)
							-- On the grid spot when it fits there, so the top's squares stay open.
							local sz = I.groundAt(cx * S, cy * S, gz + STEP + 8, gz - STEP)
							if sz and abs(sz - gz) <= STEP and hullClear(cx * S, cy * S, sz + STEP, cx * S, cy * S, sz + STEP) then
								ox, oy, gz = 0, 0, sz
							end
							j = I.addNode(cx, cy, gz, ox, oy)
							queue[#queue + 1] = j
						end
						if j and j ~= i and not hasWay(i, d, j) then
							local h = Nav.NZ[i] - Nav.NZ[j]
							I.addLink(i, j, "climb", h)
							I.addLink(j, i, "climb", -h)
							made = made + 1
						end
					end
				end
			end
		end
		if budget and SysTime() - t0 > budget then
			coroutine.yield()
			t0 = SysTime()
		end
	end
	return made
end

-- Adds climb links to the grid being made (called by sv_nav.lua's
-- generate, after the flood fill and before the grid is built). Returns how
-- many walls got one.
function Nav.ClimbPass(budget, report)
	local maxClimb = cvMaxClimb:GetFloat()
	if maxClimb <= 0 or Nav.Count == 0 then return 0 end
	setFilter()
	local maxUp = max(I.maxUp(), STEP * 2)
	if maxClimb <= maxUp then return 0 end
	local maxNodes = I.maxNodes()
	local drops = I.maxDrop()
	local total, first = 0, 1
	for round = 1, MAX_ROUNDS do
		local last = Nav.Count
		local queue = {}
		total = total + scan(first, last, queue, maxUp, maxClimb, maxNodes, budget)
		if #queue == 0 then break end
		-- Grid on the new tops (roofs, crates), then their walls next round.
		I.flood(queue, maxNodes, nil, drops, budget, report)
		first = last + 1
	end
	if report then report(string.format("Climb links at %d high walls (up to %d units).", total, maxClimb)) end
	return total
end

-- Adds climb links to the saved grid of this map without making it again.
local climbRoutine
concommand.Add("ngl_nav_climbs", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	local function tell(msg)
		msg = "[NGL] " .. msg
		print(msg)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
	end
	if climbRoutine or (Nav.Generating and Nav.Generating()) then return tell("The grid is being made, try again when it's done.") end
	if cvMaxClimb:GetFloat() <= 0 then return tell("ngl_nav_max_climb is 0: no climb links.") end
	-- The saved grid without the editor's edits, so they stay apart.
	local apply = Nav.ApplyEdits
	Nav.ApplyEdits = nil
	local ok = Nav.Load()
	Nav.ApplyEdits = apply
	if not ok then return tell("No saved grid for this map. Run ngl_nav_generate (it makes climb links too).") end
	tell("Looking for high walls to climb...")
	-- Paths aren't searched on the grid while points are being added to it
	-- (NPCs walk straight for those few seconds).
	Nav.Loaded = false
	I.clearSearches()
	climbRoutine = coroutine.create(function()
		local n = Nav.ClimbPass(0.01, tell)
		I.buildNeighbours()
		I.buildLinks()
		Nav.Loaded = Nav.Count > 0
		Nav.Save()
		if Nav.ApplyEdits then Nav.ApplyEdits() end
		tell(string.format("Done: %d climb links added, %d points. Saved.", n, Nav.Count))
	end)
	hook.Add("Tick", "NGL.Nav.Climbs", function()
		local okr, err = coroutine.resume(climbRoutine)
		if not okr then
			print("[NGL] ngl_nav_climbs failed: " .. tostring(err))
			Nav.Load() -- back to the saved grid
		end
		if not okr or coroutine.status(climbRoutine) == "dead" then
			climbRoutine = nil
			hook.Remove("Tick", "NGL.Nav.Climbs")
		end
	end)
end)
