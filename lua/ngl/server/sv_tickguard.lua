-- Steady tick: when the server can't keep up with its tick rate, NGL NPCs
-- get a little duller, step by step, until it can; when there's room again
-- they get it back.
--
-- The AI budget (ngl_ai_budget) only caps NGL's own decisions. Most of a big
-- fight's cost is the engine's work for each NPC: NextBot movement,
-- animation, sending them to players. So when ticks come late the guard
-- turns down everything that drives that work, together, with one number
-- (NGL.SvScale, 1 = as set, down to MIN):
--   * think intervals are stretched (near NPCs a player sees the least)
--   * the AI budget itself shrinks (never under 1 ms)
--   * NPCs move in steps from closer (ngl_move_step_range) and follow their
--     path without the NextBot locomotion from closer (ngl_ai_rail_range)
--   * full animation detail and real bullets come in closer
--     (ngl_anim_detail_range, ngl_ai_visual_range)
--   * far and hidden NPCs' animations advance less often
-- Every setting keeps its value: the guard only scales what it reads.
--
-- How it tells: over each second it counts the ticks that came and the ones
-- that came late (more than 1.5 tick intervals after the last one). Fewer
-- than 95% of the ticks the tick rate should give, or more than 10% late,
-- is a second behind: the scale goes down 15%. Three good seconds in a row
-- (99% of the ticks, at most 2% late) and it goes up 7%. A gap of over half
-- a second (a pause, a map change, a hitch while loading) doesn't count.
--
-- ngl_sv_tick_guard 1 (default) only on dedicated servers: on a listen
-- server or in singleplayer ticks follow the host's frame rate, so a slow
-- graphics frame would read as a slow server. 2 = everywhere, 0 = off.

NGL.SvScale = NGL.SvScale or 1
local TG = NGL.TickGuard or {}
NGL.TickGuard = TG

local cvGuard = CreateConVar("ngl_sv_tick_guard", "1", FCVAR_ARCHIVE,
	"Steady tick: when the server falls behind its tick rate, NGL NPCs think less often, move in steps and lose animation detail from closer, until it keeps up. 1 = on dedicated servers only (default), 2 = also listen servers and singleplayer (ticks follow the host's frame rate there), 0 = off.", 0, 2)
local cvMin = CreateConVar("ngl_sv_tick_guard_min", "0.35", FCVAR_ARCHIVE,
	"Steady tick: the furthest it turns NPCs down (0.35 = ranges a third, far think intervals about three times as long).", 0.1, 1)

local WINDOW = 1         -- seconds per reading
local RATE_BAD = 0.95    -- fewer ticks than this share of the tick rate: behind
local RATE_GOOD = 0.99
local LATE_BAD = 0.10    -- more late ticks than this share: behind
local LATE_GOOD = 0.02
local DOWN = 0.85
local UP = 1.07
local UP_WAIT = 3        -- good readings in a row before going up
local HITCH = 0.5        -- a gap longer than this isn't counted

local winStart, lastTick
local ticks, late, good = 0, 0, 0
TG.Rate, TG.Late = 1, 0  -- the last reading, for ngl_status and the benchmark

local function active()
	local v = cvGuard:GetInt()
	if v == 0 then return false end
	if v == 1 and not game.IsDedicated() then return false end
	return true
end

local function reset()
	winStart, lastTick = nil, nil
	ticks, late = 0, 0
end

hook.Add("Tick", "NGL.TickGuard", function()
	if not active() or #(NGL.Core and NGL.Core.List or {}) == 0 then
		if NGL.SvScale ~= 1 then NGL.SvScale = 1 end
		good = 0
		reset()
		return
	end
	local now = SysTime()
	local iv = engine.TickInterval()
	if lastTick then
		local gap = now - lastTick
		if gap > HITCH then
			reset()
		else
			ticks = ticks + 1
			if gap > iv * 1.5 then late = late + 1 end
		end
	end
	lastTick = now
	winStart = winStart or now
	local span = now - winStart
	if span < WINDOW then return end

	local rate = ticks * iv / span
	local lateShare = ticks > 0 and late / ticks or 0
	TG.Rate, TG.Late = rate, lateShare
	winStart, ticks, late = now, 0, 0

	local s = NGL.SvScale
	local lo = cvMin:GetFloat()
	if rate < RATE_BAD or lateShare > LATE_BAD then
		good = 0
		s = math.max(lo, s * DOWN)
	elseif rate >= RATE_GOOD and lateShare <= LATE_GOOD then
		good = good + 1
		if good >= UP_WAIT then
			good = 0
			s = math.min(1, s * UP)
		end
	else
		good = 0
	end
	if s > 0.995 then s = 1 end
	NGL.SvScale = s
end)

-- One line for ngl_status.
function TG.Status()
	if not active() then
		return cvGuard:GetInt() == 0 and "steady tick off" or "steady tick off (not a dedicated server; ngl_sv_tick_guard 2 turns it on)"
	end
	return string.format("steady tick: NPC detail x%.2f, last second %.0f%% of the tick rate, %.0f%% late ticks",
		NGL.SvScale, TG.Rate * 100, TG.Late * 100)
end
