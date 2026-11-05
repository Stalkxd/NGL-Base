-- ngl_debug_parts [seconds] [class]: what each part of a fight costs.
--
-- Run it during a fight (e.g. ngl_bench_keep 1, then ngl_bench_client 300
-- ngl_zombie_fast ngl_rebel, and this once the run is over). It times the
-- game's frames for a few seconds with everything on, then with one part of
-- the NPCs switched off at a time, then everything on again, and prints how
-- many milliseconds a frame each part was worth. With a class, only NPCs of
-- that class have their parts switched off (the others fight as usual).
--
-- Parts:
--   melee    no melee swings (they stand at their target)
--   leap     no leap attacks
--   damage   melee and leap blows deal no damage (no pain, flinches, blood)
--   anim     no animation update on the server (no frame advance, no legs)
--   move     no walking (BehaveUpdate does nothing)
--   think    no AI thinks (they keep going where they were going)
--   sounds   every sound from these NPCs blocked on the server
--   send     these NPCs not sent to any player (what clients spend on them)
--
-- Frames are timed on the server, from one Think to the next: in
-- singleplayer (or on a listen server) that is the whole game frame, your
-- FPS, client included. On a dedicated server it's the tick length until
-- the server can't keep up, so use singleplayer for this.

NGL.Off = NGL.Off or {}
local Off = NGL.Off

-- Is `key` switched off for `ent`? Cheap when nothing is (one table read).
function NGL.IsOff(ent, key)
	if not Off[key] then return false end
	local c = Off.class
	return c == nil or ent:GetClass() == c
end

local PARTS = { "melee", "leap", "damage", "anim", "move", "think", "sounds", "send" }
local SETTLE = 1.5 -- s after each switch before timing (the fight adjusts)

local P -- running test, or nil

local function say(ply, s)
	s = "[NGL] " .. s
	print(s)
	if IsValid(ply) and not game.SinglePlayer() and not ply:IsListenServerHost() then ply:PrintMessage(HUD_PRINTCONSOLE, s) end
end

local function matches(npc)
	return IsValid(npc) and (Off.class == nil or npc:GetClass() == Off.class)
end

-- "send": these NPCs aren't sent to anyone; afterwards each player gets
-- them again unless net culling (sv_transmit.lua) had hidden them.
local function setSend(on)
	local plys = player.GetHumans()
	for _, npc in ipairs(NGL.Core.List) do
		if matches(npc) and not npc.NGLDying then
			local hidden = npc.NGLNetHidden
			for _, ply in ipairs(plys) do
				npc:SetPreventTransmit(ply, not on or (hidden and hidden[ply]) == true)
			end
		end
	end
end

local function apply(part)
	for _, k in ipairs(PARTS) do Off[k] = nil end
	if part then Off[part] = true end
end

local function stats(list)
	local n = #list
	if n == 0 then return nil end
	local s = 0
	local sorted = {}
	for i = 1, n do s = s + list[i]; sorted[i] = list[i] end
	table.sort(sorted)
	return { avg = s / n, p95 = sorted[math.max(1, math.floor(n * 0.95))], n = n }
end

local function count()
	local n = 0
	for _, npc in ipairs(NGL.Core.List) do
		if matches(npc) and not npc.NGLDying then n = n + 1 end
	end
	return n
end

local function report(p)
	local base = {}
	for _, w in ipairs(p.windows) do
		if w.part == nil then
			for _, v in ipairs(w.frames) do base[#base + 1] = v end
		end
	end
	local b = stats(base)
	say(p.ply, "------------------------------------------------------------")
	say(p.ply, string.format("Parts of the fight, %d NGL NPCs%s, %s, %.0f s each:",
		#NGL.Core.List, p.class and (" (switched off for " .. p.class .. " only)") or "",
		game.SinglePlayer() and "singleplayer" or (game.IsDedicated() and "dedicated: frames are the tick length, use singleplayer" or "listen server"), p.secs))
	if not b then say(p.ply, "No frames timed.") return end
	say(p.ply, string.format("  everything on:  %6.2f ms a frame (%.0f FPS), p95 %.2f", b.avg, 1000 / b.avg, b.p95))
	for _, w in ipairs(p.windows) do
		local s = stats(w.frames)
		if w.part and s then
			say(p.ply, string.format("  %-8s off:   %6.2f ms (%.0f FPS)  saves %6.2f ms a frame  [%d NPCs]",
				w.part, s.avg, 1000 / s.avg, b.avg - s.avg, w.n or 0))
		end
	end
	local first, last = p.windows[1], p.windows[#p.windows]
	local s1, s2 = stats(first.frames), stats(last.frames)
	if s1 and s2 then
		say(p.ply, string.format("  (everything on at the start %.2f ms, at the end %.2f ms: the further apart, the more the fight changed while testing)", s1.avg, s2.avg))
	end
	say(p.ply, "  A part that saves more than the start/end difference is worth looking at.")
end

local function stop(aborted)
	local p = P
	if not p then return end
	P = nil
	hook.Remove("Think", "NGLPartsTest")
	if Off.send then setSend(true) end
	apply(nil)
	Off.class = nil
	if aborted then say(p.ply, "ngl_debug_parts stopped.") end
	return p
end

concommand.Add("ngl_debug_parts", function(ply, _, args)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	if args[1] == "stop" then stop(true) return end
	if P then say(ply, "ngl_debug_parts is already running (ngl_debug_parts stop).") return end
	if #NGL.Core.List == 0 then say(ply, "No NGL NPCs: start a fight first (ngl_bench_keep 1, then ngl_bench_client).") return end
	local secs = math.Clamp(tonumber(args[1]) or 5, 2, 60)
	local class = args[2]
	if class == "" then class = nil end

	-- Windows: everything on, each part off, everything on again.
	local plan = { false }
	for _, k in ipairs(PARTS) do plan[#plan + 1] = k end
	plan[#plan + 1] = false
	local p = { ply = ply, secs = secs, plan = plan, idx = 0, windows = {}, class = class }
	P = p
	Off.class = class
	say(ply, string.format("Timing %d parts, %.0f s each (about %d s; ngl_debug_parts stop to end it). Keep the window focused.",
		#PARTS, secs, math.ceil(#plan * (secs + SETTLE))))

	local function nextWindow(now)
		if Off.send then setSend(true) end
		p.idx = p.idx + 1
		local part = plan[p.idx]
		if part == nil then
			stop(false)
			report(p)
			return
		end
		part = part or nil
		apply(part)
		if part == "send" then setSend(false) end
		local w = { part = part, frames = {} }
		p.windows[#p.windows + 1] = w
		p.cur = w
		p.from = now + SETTLE
		p.to = p.from + secs
		p.last = nil
	end
	nextWindow(SysTime())

	hook.Add("Think", "NGLPartsTest", function()
		if P ~= p then return end
		local now = SysTime()
		if now >= p.to then
			p.cur.n = count()
			nextWindow(now)
			return
		end
		if now >= p.from then
			-- Unfocused, the game sleeps between frames: those don't count.
			local hasFocus = system and system.HasFocus
			if p.last and (not hasFocus or hasFocus()) then
				p.cur.frames[#p.cur.frames + 1] = (now - p.last) * 1000
			end
			p.last = now
		end
	end)
end)
