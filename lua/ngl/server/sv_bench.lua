-- NGL benchmark harness.
--
-- Spawns N NPCs of any class in two opposing teams, then measures how much
-- server CPU time they cost per tick compared with an empty baseline.
--
-- Console commands (superadmin or server console only):
--   ngl_bench <class> <count>          run one benchmark
--   ngl_bench_sweep <class> <c1,c2,..> run several counts one after another
--   ngl_bench_compare <count>          nextbot vs light vs npc_combine_s at one count
--   ngl_bench_client [count] [classA] [classB]
--                                      client FPS with two real NGL factions
--                                      fighting in front of you: half the
--                                      time looking at them, half turned away
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
	return { frame = {}, lua = {}, late = {}, spikes = {}, overruns = 0, ticks = 0, gcAlloc = 0, gcCycles = 0 }
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

local function spawnOne(class, slot, class2)
	if class2 and slot.team == 2 then class = class2 end
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

	if not classExists(job.class) or (job.class2 and not classExists(job.class2)) then
		say(job.ply, "Unknown entity class '" .. (classExists(job.class) and job.class2 or job.class) .. "', skipping.")
		return startNext()
	end

	B.Clear()

	local origin, yaw = findOrigin(job.ply)
	local now = SysTime()

	B.Active = {
		class = job.class,
		class2 = job.class2,
		clientMode = job.clientMode,
		origin = origin,
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
		job.class2 and (job.class .. " vs " .. job.class2) or job.class, job.count, cvBaseline:GetInt()))
	if job.clientMode then
		say(job.ply, "Client benchmark: keep the window focused and don't touch the mouse; the view is turned for you.")
	end
end

local function sample(run, bucket)
	local now = SysTime()
	bucket.ticks = bucket.ticks + 1

	local ms = serverFrameMs()
	if ms then bucket.frame[#bucket.frame + 1] = ms end
	local luaMs = B.LuaTime * 1000
	bucket.lua[#bucket.lua + 1] = luaMs

	-- How late NGL thinks ran this tick (the AI budget was full when this
	-- grows), and the Lua heap: what's allocated, and when a GC cycle ends
	-- (the heap shrinks). A Lua spike on the tick a cycle ended is a GC pause.
	if (B.ThinkN or 0) > 0 then bucket.late[#bucket.late + 1] = B.ThinkLate / B.ThinkN * 1000 end
	local gc = collectgarbage("count")
	local last = bucket.lastGc
	local dropped = 0
	if last then
		if gc < last then
			dropped = last - gc
			bucket.gcCycles = bucket.gcCycles + 1
		else
			bucket.gcAlloc = bucket.gcAlloc + (gc - last)
		end
	end
	bucket.lastGc = gc
	if luaMs > engine.TickInterval() * 500 and #bucket.spikes < 50 then
		bucket.spikes[#bucket.spikes + 1] = { tick = bucket.ticks, lua_ms = luaMs, heap_kb = math.floor(gc), gc_freed_kb = math.floor(dropped) }
	end

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
	-- NPC sounds and animation events a second on the server while sampling.
	local f0 = run.fx0
	if f0 and f0.stop then
		local dt = math.max(0.001, run.fxEnd - f0.t)
		local function rate(k) return ((f0.stop[k] or 0) - (f0.start[k] or 0)) / dt end
		run.fx = {
			sounds_per_s = rate("sounds"),
			sounds_cut_per_s = rate("soundsCut"),
			anim_sounds_per_s = rate("animSounds"),
			anim_sounds_cut_per_s = rate("animCut"),
			anim_events_per_s = rate("events"),
		}
	end
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
		class2 = run.class2,
		client_mode = run.clientMode or nil,
		net_cull = GetConVar("ngl_net_cull") and GetConVar("ngl_net_cull"):GetBool(),
		god = cvGod:GetBool(),
		duration = cvDuration:GetFloat(),
		time = os.date("%Y-%m-%d %H:%M:%S", run.startedAt),
		frame_source = (base and loaded) and frameSource or nil,
		baseline_frame_ms = base,
		frame_ms = loaded,
		bench_lua_ms = lua,
		think_late_ms = stats(run.loaded.late),
		lua_spikes = run.loaded.spikes,
		gc_alloc_kb_per_s = run.loaded.gcAlloc / math.max(0.001, run.duration or cvDuration:GetFloat()),
		gc_cycles = run.loaded.gcCycles,
		overruns = run.loaded.overruns,
		ticks = run.loaded.ticks,
		baseline_overruns = run.baseline.overruns,
		baseline_ticks = run.baseline.ticks,
		client = client,
		server_fx = run.fx,
	}

	-- On srcds the frame time the engine reports is wall time per frame,
	-- idle sleep included: it sits at the tick interval until the server
	-- overloads, so "added by NPCs" and "share of the tick" would be made up.
	-- What we can measure there: our Lua's share of the tick, and late ticks.
	if game.IsDedicated() then
		result.server_frame_measured = false
		result.frame_ms, result.baseline_frame_ms = nil, nil
		if lua then result.lua_tick_pct = lua.avg / tickMs * 100 end
		result.late_tick_pct = run.loaded.ticks > 0 and run.loaded.overruns / run.loaded.ticks * 100 or 0
		if client then
			for _, ph in pairs(client) do
				if type(ph) == "table" and ph.sv_ms then ph.sv_ms = nil end
			end
		end
	elseif base and loaded then
		result.added_ms = loaded.avg - base.avg
		result.added_us_per_npc = result.added_ms * 1000 / math.max(1, run.count)
		result.tick_budget_pct = loaded.avg / tickMs * 100
	end

	local p = run.ply
	say(p, "------------------------------------------------------------")
	say(p, string.format("Result: %s x%d on %s (%d tick, %s)", run.class, run.count, result.map,
		result.tickrate, result.dedicated and "dedicated" or (result.singleplayer and "singleplayer" or "listen")))
	if result.server_frame_measured == false then
		say(p, "  Server frame time:     can't be measured from Lua on a dedicated server (it reads as the tick length); see Lua share and late ticks")
	elseif not (base and loaded) then
		say(p, "  No server frame time available (no client report); only Lua time is reported.")
	else
		say(p, "  Frame time source:     " .. frameSource)
	end

	-- Validity checks: say loudly when the frame numbers can't be trusted.
	local warnings = {}
	if not game.IsDedicated() then
		warnings[#warnings + 1] = "Not a dedicated server: the frame time includes the host's rendering. Trust only the Lua line, or rerun on a local srcds."
	end
	-- The client's FPS is ruined by an unfocused window on any server; on a
	-- listen server or singleplayer the server's numbers are too.
	if client then
		for _, phase in ipairs({ "baseline", "loaded", "away" }) do
			local c = client[phase]
			if c and (c.unfocused_pct or 0) > 1 then
				warnings[#warnings + 1] = string.format("Game window was unfocused for %.0f%% of the %s phase (the engine sleeps in the background). %s numbers for that phase are invalid; keep the window focused or set engine_no_focus_sleep 0.",
					c.unfocused_pct, phase, game.IsDedicated() and "Client FPS" or "Frame")
			end
		end
	end
	-- NPCs waiting for their turn to think: they react late (ngl_ai_budget is
	-- milliseconds per tick, so a 30-tick server gives the AI less than half
	-- the time a second that a 66-tick one does).
	local late = stats(run.loaded.late)
	if late and late.avg > 250 then
		warnings[#warnings + 1] = string.format("NGL thinks ran %.0f ms late on average: the AI budget (ngl_ai_budget %.1f ms a tick, %d tick) is full and NPCs react slowly. Raise ngl_ai_budget if the server has room (few late ticks).",
			late.avg, GetConVar("ngl_ai_budget"):GetFloat(), math.Round(1 / engine.TickInterval()))
	end
	result.warnings = warnings
	for _, w in ipairs(warnings) do
		say(p, "  WARNING: " .. w)
	end
	if result.dedicated then
		say(p, string.format("  NGL Lua share of tick:  %.1f%% of the %.2f ms tick; late ticks %.1f%%. For the most NPCs this server holds, run ngl_bench_limit.",
			result.lua_tick_pct or 0, tickMs, result.late_tick_pct or 0))
	else
		say(p, "  Server frame, empty:   " .. fmt(base))
		say(p, "  Server frame, loaded:  " .. fmt(loaded))
	end
	if result.added_ms then
		say(p, string.format("  Added by NPCs:         %.3f ms/tick  (%.1f us per NPC, %.1f%% of the %.2f ms tick)",
			result.added_ms, result.added_us_per_npc, result.tick_budget_pct, tickMs))
	end
	if lua and lua.max > 0 then
		say(p, "  NGL / bench Lua:       " .. fmt(lua))
		if result.think_late_ms then say(p, "  NGL thinks late by:    " .. fmt(result.think_late_ms)) end
		say(p, string.format("  Lua heap: %.0f KB allocated a second, %d GC cycles ended", result.gc_alloc_kb_per_s, result.gc_cycles))
		for _, sp in ipairs(result.lua_spikes) do
			say(p, string.format("  Lua spike: tick %d, %.1f ms%s", sp.tick, sp.lua_ms,
				sp.gc_freed_kb > 0 and string.format(" (a GC cycle ended on it, %d KB freed)", sp.gc_freed_kb) or ""))
		end
	end
	say(p, string.format("  Late ticks, empty:     %d of %d", run.baseline.overruns, run.baseline.ticks))
	say(p, string.format("  Late ticks, loaded:    %d of %d", run.loaded.overruns, run.loaded.ticks))
	if client then
		local function avg(st) return st and st.avg or 0 end
		for _, ph in ipairs({ { "baseline", "empty" }, { "loaded", run.clientMode and "looking" or "loaded" }, { "away", "turned away" } }) do
			local c = client[ph[1]]
			local cf = c and c.client_frame_ms
			if cf and (ph[1] ~= "baseline" or run.clientMode) then
				say(p, string.format("  Client FPS, %-12s avg %.0f  (frame avg %.2f ms, p95 %.2f, p99 %.2f)", ph[2] .. ":", 1000 / cf.avg, cf.avg, cf.p95, cf.p99))
				if run.clientMode and ph[1] ~= "baseline" then
					say(p, string.format("    NPCs on the client %.0f, drawn %.0f, as pictures %.0f, hidden behind walls %.0f, too far or in fog %.0f (averages a frame)",
						avg(c.npcs_on_client), avg(c.npcs_drawn), avg(c.npcs_impostor), avg(c.npcs_occluded), avg(c.npcs_too_far)))
					if c.anim_events_per_s then
						say(p, string.format("    Client animation events %.0f/s (%.0f skipped as far), client-made NPC sounds %.0f/s",
							c.anim_events_per_s, c.anim_events_cut_per_s or 0, c.client_sounds_per_s or 0))
					end
				end
			end
		end
		local st = client.settings
		if run.clientMode and st then
			say(p, string.format("  Client settings: ngl_cl_occlusion %s, ngl_cl_impostor %s (range %s), ngl_cl_draw_range %s, %s; server ngl_net_cull %d",
				tostring(st.occlusion), tostring(st.impostor), tostring(st.impostor_range), tostring(st.draw_range), tostring(st.resolution), GetConVar("ngl_net_cull"):GetInt()))
		end
	end
	if run.fx then
		say(p, string.format("  Server NPC sounds:     %.0f/s, %.0f of them from animations (%.0f of those cut by ngl_fx_step_range), %.0f cut by ngl_fx_sounds",
			run.fx.sounds_per_s, run.fx.anim_sounds_per_s, run.fx.anim_sounds_cut_per_s, run.fx.sounds_cut_per_s))
	end
	say(p, string.format("  Alive at end:          %d / %d", alive, run.count))

	file.CreateDir("ngl_bench")
	local label = run.class2 and (run.class .. "_vs_" .. run.class2) or run.class
	if run.clientMode then label = "client_" .. label end
	local name = string.format("ngl_bench/%s_%s_%d_%s.json", result.map, label, run.count, os.date("%Y%m%d_%H%M%S", run.startedAt))
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

-- Client benchmark: turns the reporting player's view to the middle of the
-- fight, or straight away from it.
local function lookAt(run, away)
	local ply = run.reporter
	if not IsValid(ply) or not run.origin then return end
	local dir = run.origin + Vector(0, 0, 40) - ply:EyePos()
	local ang = dir:Angle()
	if away then
		ang.y = ang.y + 180
		ang.p = 0
	end
	ang.r = 0
	ply:SetEyeAngles(ang)
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
			spawnOne(run.class, slot, run.class2)
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
			local C = NGL.FX and NGL.FX.Count
			if C then run.fx0 = { start = table.Copy(C), t = SysTime() } end
			sendPhase(run, "loaded")
			say(run.ply, string.format("Sampling for %ds...", dur))
			if run.clientMode then
				-- First half looking at the fight, second half turned away.
				run.awayAt = now + dur * 0.5
				lookAt(run, false)
			end
		end

	elseif run.phase == "sampling" then
		sample(run, run.loaded)
		if run.awayAt and now >= run.awayAt then
			run.awayAt = nil
			lookAt(run, true)
			sendPhase(run, "away")
		end
		if now >= run.phaseEnd then
			run.fxEnd = SysTime()
			local C = NGL.FX and NGL.FX.Count
			if C and run.fx0 then run.fx0.stop = table.Copy(C) end
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
	B.ThinkLate, B.ThinkN = 0, 0
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
local LIMIT_CLASSES = { "ngl_combine_soldier", "ngl_bench_nextbot", "npc_combine_s" }
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
	for _, class in ipairs({ "ngl_combine_soldier", "ngl_bench_nextbot", "npc_combine_s" }) do
		queue(ply, class, count)
	end
	kick(ply)
end)

-- Client FPS: two real NGL factions fighting in front of the player.
concommand.Add("ngl_bench_client", function(ply, _, args)
	if not canRun(ply) then return end
	if not IsValid(ply) then
		say(ply, "ngl_bench_client measures your game's FPS: run it from a player's console.")
		return
	end
	local count = math.floor(tonumber(args[1] or "") or 200)
	local class = args[2] or "ngl_combine_soldier"
	local class2 = args[3] or "ngl_rebel"
	if count < 2 or count > 2000 then
		say(ply, "Count must be between 2 and 2000.")
		return
	end
	B.Queue[#B.Queue + 1] = { class = class, class2 = class2, count = count, ply = ply, clientMode = true }
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
