-- NGL benchmark harness.
--
-- Spawns N NPCs of any class in two opposing teams, then measures how much
-- server CPU time they cost per tick compared with an empty baseline.
--
-- Console commands (superadmin or server console only):
--   ngl_bench <class> <count>          run one benchmark
--   ngl_bench_sweep <class> <c1,c2,..> run several counts one after another
--   ngl_bench_compare <count>          nextbot vs light vs npc_combine_s at one count
--   ngl_bench_stop                     abort the current run / queue
--   ngl_bench_clear                    remove every benchmark NPC
--
-- Results are printed to console and saved to data/ngl_bench/*.json

local B = NGL.Bench

B.Spawned = B.Spawned or {}
B.Queue = B.Queue or {}
B.Active = nil

local cvBaseline = CreateConVar("ngl_bench_baseline", "5", FCVAR_ARCHIVE, "Seconds of empty-server sampling before spawning.", 1, 60)
local cvWarmup = CreateConVar("ngl_bench_warmup", "5", FCVAR_ARCHIVE, "Seconds to wait after spawning before sampling.", 0, 60)
local cvDuration = CreateConVar("ngl_bench_duration", "20", FCVAR_ARCHIVE, "Seconds of sampling with NPCs alive.", 1, 300)
local cvSpacing = CreateConVar("ngl_bench_spacing", "60", FCVAR_ARCHIVE, "Distance between NPCs in a team's formation.", 32, 512)
local cvGap = CreateConVar("ngl_bench_gap", "1600", FCVAR_ARCHIVE, "Distance between the two teams at spawn.", 0, 8000)
local cvGod = CreateConVar("ngl_bench_god", "1", FCVAR_ARCHIVE, "1 = NPCs get huge health so the count stays constant during sampling.", 0, 1)
local cvKeep = CreateConVar("ngl_bench_keep", "0", FCVAR_ARCHIVE, "1 = leave NPCs alive after a run.", 0, 1)
local cvWeapon = CreateConVar("ngl_bench_weapon", "weapon_smg1", FCVAR_ARCHIVE, "Weapon given to engine npc_* classes.")

local SPAWN_PER_TICK = 10
local GOD_HEALTH = 10000000

----------------------------------------------------------------------------
-- Output helpers
----------------------------------------------------------------------------

local function say(ply, msg)
	msg = "[NGL] " .. msg
	print(msg)
	-- In singleplayer / for the listen host, print() already lands in their console.
	if IsValid(ply) and not game.SinglePlayer() and not ply:IsListenServerHost() then
		ply:PrintMessage(HUD_PRINTCONSOLE, msg)
	end
end

local function canRun(ply)
	return not IsValid(ply) or ply:IsSuperAdmin()
end

----------------------------------------------------------------------------
-- Measurement
----------------------------------------------------------------------------

-- engine.ServerFrameTime() is the engine's own server frame time (the "sv"
-- number from net_graph). It includes everything: engine NPC/NextBot code,
-- physics, networking and Lua. It is client-only on current builds, so the
-- client samples it (cl_bench.lua) and reports back; this server-side read is
-- only used if a build ever exposes it here.
util.AddNetworkString("ngl_bench_phase")
util.AddNetworkString("ngl_bench_report")

local CLIENT_REPORT_TIMEOUT = 3

local function sendPhase(run, phase)
	local ply = run.reporter
	if not IsValid(ply) then return end
	net.Start("ngl_bench_phase")
	net.WriteString(phase)
	net.Send(ply)
end

net.Receive("ngl_bench_report", function(_, ply)
	local run = B.Active
	if not run or run.phase ~= "collecting" or ply ~= run.reporter then return end
	local ok, report = pcall(net.ReadTable)
	if ok and istable(report) then
		run.client = report
	end
	run.phaseEnd = 0 -- finish on the next tick
end)

local function serverFrameMs()
	if engine.ServerFrameTime then
		local ft = engine.ServerFrameTime()
		if ft then return ft * 1000 end
	end
	return nil
end

local function newBucket()
	return { frame = {}, lua = {}, overruns = 0, ticks = 0 }
end

local function stats(list)
	local n = #list
	if n == 0 then return nil end

	local sorted = {}
	local sum = 0
	for i = 1, n do
		sorted[i] = list[i]
		sum = sum + list[i]
	end
	table.sort(sorted)

	local function pct(p)
		return sorted[math.max(1, math.min(n, math.ceil(n * p)))]
	end

	return {
		avg = sum / n,
		p50 = pct(0.50),
		p95 = pct(0.95),
		p99 = pct(0.99),
		max = sorted[n],
		n = n,
	}
end

----------------------------------------------------------------------------
-- Spawning
----------------------------------------------------------------------------

local function findOrigin(ply)
	if not IsValid(ply) then
		ply = player.GetAll()[1]
	end

	if IsValid(ply) then
		local tr = util.TraceLine({
			start = ply:EyePos(),
			endpos = ply:EyePos() + ply:GetAimVector() * 4000,
			filter = ply,
			mask = MASK_SOLID_BRUSHONLY,
		})
		local yaw = ply:EyeAngles().y
		return tr.HitPos + tr.HitNormal * 8, yaw
	end

	return Vector(0, 0, 0), 0
end

-- Builds the spawn positions: two blocks of NPCs facing each other.
local function buildSlots(origin, yaw, count)
	local forward = Angle(0, yaw, 0):Forward()
	local right = Angle(0, yaw, 0):Right()
	local spacing = cvSpacing:GetFloat()
	local halfGap = cvGap:GetFloat() * 0.5

	local perTeam = math.ceil(count / 2)
	local cols = math.max(1, math.ceil(math.sqrt(perTeam)))
	local slots = {}

	for i = 0, count - 1 do
		local team = (i % 2) + 1
		local idx = math.floor(i / 2)
		local row, col = math.floor(idx / cols), idx % cols
		local side = (team == 1) and -1 or 1

		local pos = origin
			+ forward * (side * (halfGap + row * spacing))
			+ right * ((col - (cols - 1) * 0.5) * spacing)

		-- Drop to the floor.
		local tr = util.TraceLine({
			start = pos + Vector(0, 0, 64),
			endpos = pos - Vector(0, 0, 1024),
			mask = MASK_SOLID_BRUSHONLY,
		})
		if tr.Hit and not tr.StartSolid then
			pos = tr.HitPos + Vector(0, 0, 2)
		end

		slots[#slots + 1] = {
			pos = pos,
			team = team,
			yaw = (team == 1) and yaw or (yaw + 180),
		}
	end

	return slots
end

local function spawnOne(class, slot)
	local ent = ents.Create(class)
	if not IsValid(ent) then return nil end

	ent:SetPos(slot.pos)
	ent:SetAngles(Angle(0, slot.yaw, 0))
	ent.NGLTeam = slot.team
	ent.NGLBench = true
	if cvGod:GetBool() then
		ent.NGLStartHealth = GOD_HEALTH
	end

	local isEngineNPC = string.StartWith(class, "npc_")
	if isEngineNPC and cvWeapon:GetString() ~= "" then
		ent:SetKeyValue("additionalequipment", cvWeapon:GetString())
	end

	ent:Spawn()
	ent:Activate()

	if isEngineNPC and cvGod:GetBool() then
		ent:SetMaxHealth(GOD_HEALTH)
		ent:SetHealth(GOD_HEALTH)
	end

	B.Spawned[#B.Spawned + 1] = ent
	return ent
end

-- Engine NPCs of the same class are friends by default; make the teams hate each other.
local function setupEngineRelationships()
	local byTeam = { {}, {} }
	for _, ent in ipairs(B.Spawned) do
		if IsValid(ent) and ent:IsNPC() and byTeam[ent.NGLTeam] then
			table.insert(byTeam[ent.NGLTeam], ent)
		end
	end

	for _, a in ipairs(byTeam[1]) do
		for _, b in ipairs(byTeam[2]) do
			a:AddEntityRelationship(b, D_HT, 99)
			b:AddEntityRelationship(a, D_HT, 99)
		end
	end
end

function B.Clear()
	for _, ent in ipairs(B.Spawned) do
		if IsValid(ent) then ent:Remove() end
	end
	B.Spawned = {}
end

local function aliveCount()
	local n = 0
	for _, ent in ipairs(B.Spawned) do
		if IsValid(ent) and ent:Health() > 0 then n = n + 1 end
	end
	return n
end

----------------------------------------------------------------------------
-- Run state machine (driven from Tick)
----------------------------------------------------------------------------

local function classExists(class)
	if scripted_ents.GetStored(class) then return true end
	if list.Get("NPC")[class] then return true end
	local probe = ents.Create(class)
	if IsValid(probe) then
		probe:Remove()
		return true
	end
	return false
end

local function startNext()
	local job = table.remove(B.Queue, 1)
	if not job then return end

	if not classExists(job.class) then
		say(job.ply, "Unknown entity class '" .. job.class .. "', skipping.")
		return startNext()
	end

	B.Clear()

	local origin, yaw = findOrigin(job.ply)
	local now = SysTime()

	B.Active = {
		class = job.class,
		count = job.count,
		ply = job.ply,
		limit = job.limit,
		duration = job.duration,
		reporter = IsValid(job.ply) and job.ply or player.GetAll()[1],
		phase = "baseline",
		phaseEnd = now + cvBaseline:GetFloat(),
		slots = buildSlots(origin, yaw, job.count),
		nextSlot = 1,
		baseline = newBucket(),
		loaded = newBucket(),
		lastTick = nil,
		startedAt = os.time(),
	}

	sendPhase(B.Active, "baseline")
	say(job.ply, string.format("Benchmark %s x%d: sampling empty baseline for %ds...",
		job.class, job.count, cvBaseline:GetInt()))
end

local function sample(run, bucket)
	local now = SysTime()
	bucket.ticks = bucket.ticks + 1

	local ms = serverFrameMs()
	if ms then bucket.frame[#bucket.frame + 1] = ms end
	bucket.lua[#bucket.lua + 1] = B.LuaTime * 1000

	-- A tick that arrives much later than the tick interval means the server
	-- could not keep up (or, on a listen server, the client frame was slow).
	if run.lastTick and (now - run.lastTick) > engine.TickInterval() * 1.5 then
		bucket.overruns = bucket.overruns + 1
	end
	run.lastTick = now
end

local function fmt(s)
	if not s then return "n/a" end
	return string.format("avg %.3f  p50 %.3f  p95 %.3f  p99 %.3f  max %.3f ms", s.avg, s.p50, s.p95, s.p99, s.max)
end

local function finish(run)
	local base = stats(run.baseline.frame)
	local loaded = stats(run.loaded.frame)
	local frameSource = "server"
	local client = run.client
	if not (base and loaded) and client and client.baseline and client.loaded then
		base = client.baseline.sv_ms
		loaded = client.loaded.sv_ms
		frameSource = "client net_graph"
	end
	local lua = stats(run.loaded.lua)
	local tickMs = engine.TickInterval() * 1000
	local alive = aliveCount()

	local result = {
		version = NGL.Version,
		map = game.GetMap(),
		class = run.class,
		count = run.count,
		alive_at_end = alive,
		tickrate = math.Round(1 / engine.TickInterval()),
		dedicated = game.IsDedicated(),
		singleplayer = game.SinglePlayer(),
		players = player.GetCount(),
		bullets = GetConVar("ngl_bench_bullets"):GetBool(),
		god = cvGod:GetBool(),
		duration = cvDuration:GetFloat(),
		time = os.date("%Y-%m-%d %H:%M:%S", run.startedAt),
		frame_source = (base and loaded) and frameSource or nil,
		baseline_frame_ms = base,
		frame_ms = loaded,
		bench_lua_ms = lua,
		overruns = run.loaded.overruns,
		ticks = run.loaded.ticks,
		baseline_overruns = run.baseline.overruns,
		baseline_ticks = run.baseline.ticks,
		client = client,
	}

	if base and loaded then
		result.added_ms = loaded.avg - base.avg
		result.added_us_per_npc = result.added_ms * 1000 / math.max(1, run.count)
		result.tick_budget_pct = loaded.avg / tickMs * 100
	end

	local p = run.ply
	say(p, "------------------------------------------------------------")
	say(p, string.format("Result: %s x%d on %s (%d tick, %s)", run.class, run.count, result.map,
		result.tickrate, result.dedicated and "dedicated" or (result.singleplayer and "singleplayer" or "listen")))
	if not (base and loaded) then
		say(p, "  No server frame time available (no client report); only Lua time is reported.")
	else
		say(p, "  Frame time source:     " .. frameSource)
	end

	-- Validity checks: say loudly when the frame numbers can't be trusted.
	local warnings = {}
	if not game.IsDedicated() then
		warnings[#warnings + 1] = "Not a dedicated server: the frame time includes the host's rendering. Trust only the Lua line, or rerun on a local srcds."
	end
	if client then
		for _, phase in ipairs({ "baseline", "loaded" }) do
			local c = client[phase]
			if c and (c.unfocused_pct or 0) > 1 then
				warnings[#warnings + 1] = string.format("Game window was unfocused for %.0f%% of the %s phase (engine sleeps in the background). Frame numbers are invalid; keep the window focused or set engine_no_focus_sleep 0.", c.unfocused_pct, phase)
			end
		end
	end
	result.warnings = warnings
	for _, w in ipairs(warnings) do
		say(p, "  WARNING: " .. w)
	end
	say(p, "  Server frame, empty:   " .. fmt(base))
	say(p, "  Server frame, loaded:  " .. fmt(loaded))
	if result.dedicated then
		-- On srcds the networked frame time is wall time per frame including the
		-- idle sleep, so it sits at the tick interval until the server overloads.
		-- Late ticks (and ngl_bench_limit) are the real signal there.
		say(p, string.format("  Note: on a dedicated server the frame time stays at ~%.2f ms (the tick interval) until it overloads. Use late ticks, or ngl_bench_limit.", tickMs))
	elseif result.added_ms then
		say(p, string.format("  Added by NPCs:         %.3f ms/tick  (%.1f us per NPC, %.1f%% of the %.2f ms tick)",
			result.added_ms, result.added_us_per_npc, result.tick_budget_pct, tickMs))
	end
	if run.class == "ngl_bench_nextbot" or run.class == "ngl_bench_light" then
		say(p, "  Bench AI Lua only:     " .. fmt(lua))
	end
	say(p, string.format("  Late ticks, empty:     %d of %d", run.baseline.overruns, run.baseline.ticks))
	say(p, string.format("  Late ticks, loaded:    %d of %d", run.loaded.overruns, run.loaded.ticks))
	if client and client.loaded and client.loaded.client_frame_ms then
		local cf = client.loaded.client_frame_ms
		say(p, string.format("  Client FPS, loaded:    avg %.0f  (p95 frame %.2f ms)", 1000 / cf.avg, cf.p95))
	end
	say(p, string.format("  Alive at end:          %d / %d", alive, run.count))

	file.CreateDir("ngl_bench")
	local name = string.format("ngl_bench/%s_%s_%d_%s.json", result.map, run.class, run.count, os.date("%Y%m%d_%H%M%S", run.startedAt))
	file.Write(name, util.TableToJSON(result, true))
	say(p, "  Saved to garrysmod/data/" .. name)
	say(p, "------------------------------------------------------------")

	local L = run.limit
	if L then
		local latePct = run.loaded.ticks > 0 and (run.loaded.overruns / run.loaded.ticks * 100) or 0
		L.results[#L.results + 1] = { count = run.count, late_pct = latePct, lua_ms = lua and lua.avg or 0, alive = alive }

		local nextCount = L.ladder[L.idx + 1]
		if latePct <= L.maxLatePct and nextCount then
			L.idx = L.idx + 1
			table.insert(B.Queue, 1, { class = run.class, count = nextCount, ply = run.ply, limit = L, duration = run.duration })
		else
			local okCount = 0
			say(p, "============================================================")
			say(p, string.format("Limit for %s (pass = at most %.0f%% late ticks):", run.class, L.maxLatePct))
			for _, r in ipairs(L.results) do
				local pass = r.late_pct <= L.maxLatePct
				if pass then okCount = r.count end
				say(p, string.format("  %5d NPCs: %5.1f%% late ticks, Lua %.2f ms  %s", r.count, r.late_pct, r.lua_ms, pass and "PASS" or "FAIL"))
			end
			if okCount == L.ladder[#L.ladder] and latePct <= L.maxLatePct then
				say(p, string.format("  => Still holding %d tick at %d NPCs (top of the ladder).", result.tickrate, okCount))
			else
				say(p, string.format("  => Holds %d tick up to %d NPCs.", result.tickrate, okCount))
			end
			say(p, "============================================================")
			L.max_ok = okCount
			file.Write(string.format("ngl_bench/limit_%s_%s_%s.json", result.map, run.class, os.date("%Y%m%d_%H%M%S")),
				util.TableToJSON({ class = run.class, map = result.map, dedicated = result.dedicated, tickrate = result.tickrate,
					max_late_pct = L.maxLatePct, max_ok = okCount, results = L.results }, true))
		end
	end

	if not cvKeep:GetBool() or #B.Queue > 0 then
		B.Clear()
	end

	B.Active = nil
	if #B.Queue > 0 then
		timer.Simple(2, startNext)
	end
end

hook.Add("Tick", "NGL.Bench.Harness", function()
	local run = B.Active
	if not run then
		B.LuaTime = 0
		return
	end

	local now = SysTime()

	if run.phase == "baseline" then
		sample(run, run.baseline)
		if now >= run.phaseEnd then
			sendPhase(run, "pause")
			run.phase = "spawning"
			say(run.ply, "Spawning " .. run.count .. " NPCs...")
		end

	elseif run.phase == "spawning" then
		for _ = 1, SPAWN_PER_TICK do
			local slot = run.slots[run.nextSlot]
			if not slot then break end
			spawnOne(run.class, slot)
			run.nextSlot = run.nextSlot + 1
		end

		if run.nextSlot > #run.slots then
			setupEngineRelationships()
			run.phase = "warmup"
			run.phaseEnd = now + cvWarmup:GetFloat()
			say(run.ply, string.format("Spawned %d. Warming up for %ds...", #B.Spawned, cvWarmup:GetInt()))
		end

	elseif run.phase == "warmup" then
		if now >= run.phaseEnd then
			run.phase = "sampling"
			local dur = run.duration or cvDuration:GetFloat()
			run.phaseEnd = now + dur
			run.lastTick = nil
			sendPhase(run, "loaded")
			say(run.ply, string.format("Sampling for %ds...", dur))
		end

	elseif run.phase == "sampling" then
		sample(run, run.loaded)
		if now >= run.phaseEnd then
			if IsValid(run.reporter) then
				run.phase = "collecting"
				run.phaseEnd = now + CLIENT_REPORT_TIMEOUT
				sendPhase(run, "stop")
			else
				finish(run)
			end
		end

	elseif run.phase == "collecting" then
		if now >= run.phaseEnd then
			finish(run)
		end
	end

	-- B.LuaTime accumulates agent Lua time between two harness ticks. Whether
	-- the light driver runs before or after this hook only shifts it by a tick.
	B.LuaTime = 0
end)

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------

local function queue(ply, class, count)
	count = math.floor(tonumber(count) or 0)
	if count < 1 or count > 2000 then
		say(ply, "Count must be between 1 and 2000.")
		return false
	end
	B.Queue[#B.Queue + 1] = { class = class, count = count, ply = ply }
	return true
end

local function kick(ply)
	if B.Active then
		say(ply, "A benchmark is running; added to the queue (" .. #B.Queue .. " waiting).")
	else
		startNext()
	end
end

concommand.Add("ngl_bench", function(ply, _, args)
	if not canRun(ply) then return end
	if not args[1] or not args[2] then
		say(ply, "Usage: ngl_bench <class> <count>   e.g. ngl_bench ngl_bench_light 100")
		return
	end
	if queue(ply, args[1], args[2]) then kick(ply) end
end)

concommand.Add("ngl_bench_sweep", function(ply, _, args)
	if not canRun(ply) then return end
	if not args[1] or not args[2] then
		say(ply, "Usage: ngl_bench_sweep <class> <c1,c2,...>   e.g. ngl_bench_sweep ngl_bench_light 25,50,100,150")
		return
	end
	local counts = table.concat(args, ",", 2)
	for c in string.gmatch(counts, "%d+") do
		queue(ply, args[1], c)
	end
	kick(ply)
end)

-- Stress mode: climb a ladder of NPC counts until the server starts missing
-- ticks. Works on any server; on a dedicated server it is the most honest
-- number we have, because it measures the point where the CPU runs out.
local LIMIT_LADDER = { 100, 200, 300, 400, 500, 600, 800, 1000, 1250, 1500, 2000 }
local LIMIT_CLASSES = { "ngl_bench_light", "ngl_bench_nextbot", "npc_combine_s" }
local cvLimitLate = CreateConVar("ngl_bench_limit_late", "1", FCVAR_ARCHIVE, "ngl_bench_limit: max % of late ticks that still counts as a pass.", 0, 100)
local cvLimitDuration = CreateConVar("ngl_bench_limit_duration", "10", FCVAR_ARCHIVE, "ngl_bench_limit: seconds of sampling per step.", 3, 120)

concommand.Add("ngl_bench_limit", function(ply, _, args)
	if not canRun(ply) then return end
	local which = args[1] or "all"
	local classes = (which == "all") and LIMIT_CLASSES or { which }
	local startAt = tonumber(args[2] or "") or LIMIT_LADDER[1]

	for _, class in ipairs(classes) do
		local ladder = {}
		for _, c in ipairs(LIMIT_LADDER) do
			if c >= startAt then ladder[#ladder + 1] = c end
		end
		if #ladder > 0 then
			local L = { ladder = ladder, idx = 1, results = {}, maxLatePct = cvLimitLate:GetFloat() }
			B.Queue[#B.Queue + 1] = { class = class, count = ladder[1], ply = ply, limit = L, duration = cvLimitDuration:GetFloat() }
		end
	end
	say(ply, "Stress test queued for: " .. table.concat(classes, ", ") .. ". Steps: " .. table.concat(LIMIT_LADDER, ", ", 1) .. " (stops at the first failing step).")
	kick(ply)
end)

concommand.Add("ngl_bench_compare", function(ply, _, args)
	if not canRun(ply) then return end
	local count = args[1] or "100"
	for _, class in ipairs({ "ngl_bench_light", "ngl_bench_nextbot", "npc_combine_s" }) do
		queue(ply, class, count)
	end
	kick(ply)
end)

concommand.Add("ngl_bench_stop", function(ply)
	if not canRun(ply) then return end
	B.Queue = {}
	if B.Active then sendPhase(B.Active, "pause") end
	B.Active = nil
	B.Clear()
	say(ply, "Benchmark stopped and NPCs removed.")
end)

concommand.Add("ngl_bench_clear", function(ply)
	if not canRun(ply) then return end
	B.Clear()
	say(ply, "Benchmark NPCs removed.")
end)
