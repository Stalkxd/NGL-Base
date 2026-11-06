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
--   clanim   the server stops advancing the animation (legs and playback
--            rate still sent), and your client plays it on its own from
--            when it started: what moving animation to the client would
--            save (the "client animation" idea). Hitboxes on the server
--            stay in one pose meanwhile. Compare with "anim off": what
--            clanim doesn't save is the cost of the client doing it.
--   move     no walking (BehaveUpdate does nothing)
--   think    no AI thinks (they keep going where they were going)
--   sounds   every sound from these NPCs blocked on the server
--   send     these NPCs not sent to any player (what clients spend on them)
--
-- Frames are timed on your client (frame time and the server frame time
-- net_graph shows), late ticks on the server. Singleplayer or a local
-- dedicated server you're connected to both work.

NGL.Off = NGL.Off or {}
local Off = NGL.Off

-- Is `key` switched off for `ent`? Cheap when nothing is (one table read).
function NGL.IsOff(ent, key)
	if not Off[key] then return false end
	local c = Off.class
	return c == nil or ent:GetClass() == c
end

local PARTS = { "melee", "leap", "damage", "anim", "clanim", "move", "think", "sounds", "send", "draw", "lowlod" }
-- Switched on the client of whoever ran it, not here:
--   draw     these NPCs not drawn (still sent and animated on the client)
--   lowlod   drawn with the model's lowest detail and no shadow
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

local function count()
	local n = 0
	for _, npc in ipairs(NGL.Core.List) do
		if matches(npc) and not npc.NGLDying then n = n + 1 end
	end
	return n
end

-- Frames are timed on the client of the player who ran it (the server's
-- Think in singleplayer runs once a tick, catching up several ticks in one
-- frame, so it only ever saw the tick length): its frame time and the
-- server frame time net_graph shows, for each window. The server counts
-- late ticks per window itself (the only honest number on a dedicated
-- server).
util.AddNetworkString("ngl_parts")
local MSG_START, MSG_END, MSG_DONE = 1, 2, 3

local function send(p, kind, i)
	if not IsValid(p.ply) then return end
	net.Start("ngl_parts")
	net.WriteUInt(kind, 2)
	net.WriteUInt(i or 0, 8)
	if kind == MSG_START then
		local w = p.windows[i]
		net.WriteString(w and w.part or "")
		net.WriteString(p.class or "")
	end
	net.Send(p.ply)
end

local function report(p)
	local c = p.client or {}
	say(p.ply, "------------------------------------------------------------")
	say(p.ply, string.format("Parts of the fight, %d NGL NPCs%s, %s, %.0f s each:",
		#NGL.Core.List, p.class and (" (switched off for " .. p.class .. " only)") or "",
		game.SinglePlayer() and "singleplayer" or (game.IsDedicated() and "dedicated" or "listen server"), p.secs))
	if not p.client then say(p.ply, "  (no client report: only late ticks below)") end
	-- Everything on: both "on" windows together.
	local fs, ss, fn, lt, tk = 0, 0, 0, 0, 0
	for i, w in ipairs(p.windows) do
		local r = c[i]
		if not w.part then
			if r and r.n > 0 then fs, ss, fn = fs + r.frame * r.n, ss + r.sv * r.n, fn + r.n end
			lt, tk = lt + w.late, tk + w.ticks
		end
	end
	local bf, bs = fn > 0 and fs / fn or nil, fn > 0 and ss / fn or nil
	local function line(label, r, w, saves)
		local late = w.ticks > 0 and w.late / w.ticks * 100 or 0
		if r and r.n > 0 then
			say(p.ply, string.format("  %-14s frame %6.2f ms (%3.0f FPS)  server %6.2f ms  late ticks %4.1f%%%s",
				label, r.frame, 1000 / r.frame, r.sv, late,
				saves and bf and string.format("  saves %6.2f ms frame, %6.2f ms server", bf - r.frame, bs - r.sv) or ""))
		else
			say(p.ply, string.format("  %-14s late ticks %4.1f%%", label, late))
		end
	end
	for i, w in ipairs(p.windows) do
		line(w.part and (w.part .. " off:") or (i == 1 and "on, start:" or "on, end:"), c[i], w, w.part ~= nil)
	end
	say(p.ply, "  The start and end lines show how much the fight itself changed while testing; a part that saves more than that is worth looking at.")
	say(p.ply, "  'server' is the server's own frame time (net_graph's sv): in singleplayer it's most of the frame.")
	say(p.ply, "  clanim: the server's animation frozen and your client playing it itself. Close to 'anim off' = moving animation to clients is worth it; watch that NPCs still animate normally during it.")
end

net.Receive("ngl_parts", function(_, ply)
	local p = P
	if not p or not p.waiting or ply ~= p.ply then return end
	local n = net.ReadUInt(8)
	local c = {}
	for i = 1, n do
		c[i] = { frame = net.ReadFloat(), sv = net.ReadFloat(), n = net.ReadUInt(16) }
	end
	p.client = c
	p.reportAt = 0
end)

local function stop(aborted)
	local p = P
	if not p then return end
	P = nil
	hook.Remove("Think", "NGLPartsTest")
	hook.Remove("Tick", "NGLPartsTest")
	if Off.send then setSend(true) end
	apply(nil)
	Off.class = nil
	if aborted then
		send(p, MSG_END)
		say(p.ply, "ngl_debug_parts stopped.")
	end
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
		if p.cur and p.timing then send(p, MSG_END) end
		p.timing = false
		if Off.send then setSend(true) end
		p.idx = p.idx + 1
		local part = plan[p.idx]
		if part == nil then
			-- All done: switch everything back on, then wait for the client.
			if Off.send then setSend(true) end
			apply(nil)
			p.waiting = true
			p.reportAt = now + 3
			send(p, MSG_DONE, #p.windows)
			return
		end
		part = part or nil
		apply(part)
		if part == "send" then setSend(false) end
		local w = { part = part, late = 0, ticks = 0 }
		p.windows[#p.windows + 1] = w
		p.cur = w
		p.from = now + SETTLE
		p.to = p.from + secs
	end
	nextWindow(SysTime())

	hook.Add("Think", "NGLPartsTest", function()
		if P ~= p then return end
		local now = SysTime()
		if p.waiting then
			if now >= p.reportAt then
				stop(false)
				report(p)
			end
			return
		end
		if now >= p.to then
			p.cur.n = count()
			nextWindow(now)
		elseif not p.timing and now >= p.from then
			p.timing = true
			p.lastTick = nil
			send(p, MSG_START, #p.windows)
		end
	end)
	local interval = engine.TickInterval()
	hook.Add("Tick", "NGLPartsTest", function()
		if P ~= p or not p.timing then return end
		local now = SysTime()
		local w = p.cur
		if p.lastTick then
			w.ticks = w.ticks + 1
			if now - p.lastTick > interval * 1.5 then w.late = w.late + 1 end
		end
		p.lastTick = now
	end)
end)
