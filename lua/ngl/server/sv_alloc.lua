-- ngl_debug_alloc [seconds]: where NGL's Lua garbage comes from.
--
-- Every new table, vector, angle or string the Lua code makes is garbage
-- once it's dropped, and the garbage collector cleans it up in steps; a
-- big step is a slow tick (the "GC" spikes in benchmark reports). This
-- measures, for a few seconds, how much memory each part of NGL makes a
-- second. The collector is paused meanwhile, so the numbers are exact (the
-- heap only grows), and started again at the end.
--
-- Parts measured: every NGL hook (the AI scheduler, path search, net
-- culling...), the NPCs' own methods called by the engine (movement and
-- animation every tick, damage, animation events), and inside the AI
-- think, the crowd checks and the enemy search. Each part counts only its
-- own memory, not what a part inside it makes (a sound hook running during
-- a think counts for the sound hook). "Everything else" is the rest:
-- engine callbacks into other addons, GMod itself.

NGL.Alloc = NGL.Alloc or {}
local A = NGL.Alloc
local count = collectgarbage

-- The NPC methods measured. Only NPCs there when it starts.
local METHODS = { "BehaveUpdate", "BodyUpdate", "HandleAnimEvent", "OnInjured", "OnKilled", "OnTraceAttack", "NGLUpdatePose", "NGLResetPose" }

local P -- running probe, or nil
local function measure(key, fn, ...)
	local p = P
	if not p then return fn(...) end
	local c0 = count("count")
	local before = p.child
	p.child = 0
	local a, b = fn(...)
	local used = count("count") - c0
	p.self[key] = (p.self[key] or 0) + used - p.child
	p.calls[key] = (p.calls[key] or 0) + 1
	p.child = before + used
	return a, b
end
A.Measure = measure
function A.On() return P ~= nil end

local function stop(ply)
	local p = P
	if not p then return end
	P = nil
	local total = count("count") - p.kb0
	count("restart")
	-- Put everything back.
	for event, list in pairs(p.hooks) do
		for name, fn in pairs(list) do hook.Add(event, name, fn) end
	end
	for npc, old in pairs(p.npcs) do
		if IsValid(npc) then
			local t = npc:GetTable()
			for m, fn in pairs(old) do t[m] = fn or nil end
		end
	end
	local dt = math.max(0.001, SysTime() - p.t0)
	local function say(s)
		print(s)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) end
	end
	local rows, sum = {}, 0
	for k, kb in pairs(p.self) do
		rows[#rows + 1] = { k, kb }
		sum = sum + kb
	end
	table.sort(rows, function(x, y) return x[2] > y[2] end)
	say(string.format("[NGL] Lua memory made in %.1f s, %d NGL NPCs: %.0f KB a second in all", dt, #NGL.Core.List, total / dt))
	for _, r in ipairs(rows) do
		local calls = p.calls[r[1]] or 0
		say(string.format("  %8.0f KB/s  %4.1f%%  %s  (%.0f calls/s, %.2f KB each)", r[2] / dt, r[2] / math.max(total, 0.001) * 100,
			r[1], calls / dt, calls > 0 and r[2] / calls or 0))
	end
	say(string.format("  %8.0f KB/s  %4.1f%%  everything else (engine callbacks, other addons, GMod)", (total - sum) / dt, (total - sum) / math.max(total, 0.001) * 100))
end

concommand.Add("ngl_debug_alloc", function(ply, _, args)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	if P then
		local s = "[NGL] ngl_debug_alloc is already running."
		print(s)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) end
		return
	end
	local secs = math.Clamp(tonumber(args[1]) or 3, 1, 10)
	local p = { self = {}, calls = {}, child = 0, hooks = {}, npcs = {} }

	-- NGL hooks: wrapped while measuring, then put back as they were.
	for event, list in pairs(hook.GetTable()) do
		for name, fn in pairs(list) do
			if type(name) == "string" and name:sub(1, 4) == "NGL." and type(fn) == "function" then
				p.hooks[event] = p.hooks[event] or {}
				p.hooks[event][name] = fn
			end
		end
	end
	for event, list in pairs(p.hooks) do
		for name, fn in pairs(list) do
			local key = "hook " .. event .. " " .. name
			hook.Add(event, name, function(...) return measure(key, fn, ...) end)
		end
	end
	-- NPC methods: a field on each NPC over its class's method.
	for _, npc in ipairs(NGL.Core.List) do
		if IsValid(npc) then
			local t = npc:GetTable()
			local old = {}
			p.npcs[npc] = old
			for _, m in ipairs(METHODS) do
				local fn = npc[m]
				if type(fn) == "function" then
					old[m] = rawget(t, m) or false -- its own field, if it had one
					local key = "NPC " .. m
					t[m] = function(...) return measure(key, fn, ...) end
				end
			end
		end
	end

	count("collect")
	count("stop")
	p.t0, p.kb0 = SysTime(), count("count")
	P = p
	local s = string.format("[NGL] Measuring Lua memory for %d s (garbage collector paused)...", secs)
	print(s)
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) end
	-- Real time, not game time: a paused or slowed game still ends it.
	local ends = SysTime() + secs
	hook.Add("Think", "NGLAllocProbe", function()
		if SysTime() < ends then return end
		hook.Remove("Think", "NGLAllocProbe")
		stop(ply)
	end)
end)
