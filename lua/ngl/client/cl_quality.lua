-- Steady FPS: the client's NPC detail follows its frame rate.
--
-- With ngl_cl_fps_target set (say 60), this client watches its own frame
-- rate. Below the target it brings NPC detail in a step at a time: the
-- picture range, the full-model budget (ngl_cl_full_max), and the shadow,
-- model detail, weapon, face and blood mark ranges all shrink by the same
-- factor, down to MIN_SCALE of what they're set to. Back above the target,
-- with room to spare, they grow back slowly. Your settings themselves never
-- change: NGL.ClScale multiplies them where they're read (cl_init.lua,
-- cl_impostor.lua).
--
-- What it can't fix: a frame that's slow for other reasons (the map, other
-- addons, in singleplayer the server's own work) stays slow, and detail
-- then sits at the minimum until it speeds up. ngl_cl_fps_status says
-- where it is.

local cvTarget = CreateClientConVar("ngl_cl_fps_target", "0", true, false,
	"Steady FPS: below this frame rate, NGL NPC detail (picture range, full models, shadows, model detail, weapons) is lowered step by step, and raised again when there's room. 0 = off.", 0, 1000)

NGL.ClScale = 1

local MIN_SCALE = 0.4  -- lowest share of the set ranges
local WINDOW = 0.5     -- seconds of frames averaged per decision
local DOWN = 0.85      -- each step down
local UP = 1.05        -- each step up
local UP_WAIT = 3      -- seconds after a step down before stepping up
local LOW, HIGH = 0.95, 1.12 -- below target * LOW: down; above target * HIGH: up

local sum, n, windowEnd, lastDown = 0, 0, 0, 0
local lastFps = 0

hook.Add("Think", "NGL.Quality", function()
	local target = cvTarget:GetFloat()
	if target <= 0 then
		NGL.ClScale = 1
		n, sum = 0, 0
		return
	end
	-- fps_max caps the frame rate: a target above it could never be met.
	local cap = GetConVar("fps_max")
	cap = cap and cap:GetFloat() or 0
	if cap > 0 and target > cap * 0.97 then target = cap * 0.97 end

	local now = RealTime()
	-- Unfocused (the engine sleeps) or in the pause menu: not real frames.
	if not system.HasFocus() or (gui.IsGameUIVisible and gui.IsGameUIVisible()) then
		n, sum, windowEnd = 0, 0, now + WINDOW
		return
	end
	local ft = RealFrameTime()
	if ft > 0 and ft < 1 then
		sum = sum + ft
		n = n + 1
	end
	if now < windowEnd then return end
	windowEnd = now + WINDOW
	if n < 3 then
		n, sum = 0, 0
		return
	end
	local fps = n / sum
	lastFps = fps
	n, sum = 0, 0
	local s = NGL.ClScale or 1
	if fps < target * LOW then
		if s > MIN_SCALE then
			NGL.ClScale = math.max(MIN_SCALE, s * DOWN)
			lastDown = now
		end
	elseif fps > target * HIGH and s < 1 and now - lastDown > UP_WAIT then
		NGL.ClScale = math.min(1, s * UP)
	end
end)

concommand.Add("ngl_cl_fps_status", function()
	local target = cvTarget:GetFloat()
	if target <= 0 then
		print("[NGL] Steady FPS is off (ngl_cl_fps_target 0).")
		return
	end
	local I = NGL.Impostor
	local bd = I and I.BudgetD and I.BudgetD() or math.huge
	print(string.format("[NGL] Steady FPS: target %d, last %.0f FPS, NPC detail at %d%% of your settings, full models up to %s units.",
		target, lastFps, math.floor((NGL.ClScale or 1) * 100 + 0.5),
		bd < math.huge and tostring(math.floor(math.sqrt(bd))) or "the picture range"))
end)

-- ngl_cl_debug_alloc [seconds]: how much new Lua memory this client makes
-- a second (garbage the collector has to clear later, in pauses). The
-- collector is paused while it measures, so the number is exact.
concommand.Add("ngl_cl_debug_alloc", function(_, _, args)
	local secs = math.Clamp(tonumber(args[1]) or 5, 1, 60)
	collectgarbage("collect")
	collectgarbage("stop")
	local k0, t0 = collectgarbage("count"), SysTime()
	print(string.format("[NGL] Measuring this client's Lua allocations for %d s...", secs))
	timer.Simple(secs, function()
		local kb, dt = collectgarbage("count") - k0, SysTime() - t0
		collectgarbage("restart")
		print(string.format("[NGL] Client Lua: %.0f KB of new memory a second (%.1f MB in %.1f s).", kb / dt, kb / 1024, dt))
	end)
end)
