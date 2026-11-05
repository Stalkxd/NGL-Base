-- Effect budget for NPC bullets.
--
-- Every real bullet (near players, sv_core.lua) makes a tracer, an impact
-- (sparks, dust or blood, with a decal and a sound) and, for some guns, a
-- muzzle flash, on every client that can see it. In a 200 NPC firefight that
-- is hundreds of effects a second, and clients pay for all of them. Close to
-- a player nothing changes. Further out:
--   tracers        only on every ngl_fx_tracer_every-th shot of each NPC
--   impacts        at most ngl_fx_impacts a second over the whole server
--                  (damage is never skipped, only the effect)
--   muzzle flashes only sent to players within ngl_fx_muzzle_range
--   sounds         NPC sounds (guns, voices, claws, footsteps from the
--                  animations) further than ngl_fx_near from every player:
--                  at most ngl_fx_sounds a second over the whole server

NGL.FX = NGL.FX or {}
local FX = NGL.FX

local cvNear = CreateConVar("ngl_fx_near", "1200", FCVAR_ARCHIVE,
	"NGL bullet effects (tracers, impacts) within this distance of a player are never cut.", 0, 50000)
local cvTracerEvery = CreateConVar("ngl_fx_tracer_every", "3", FCVAR_ARCHIVE,
	"NGL NPCs further than ngl_fx_near from every player draw a tracer on every Nth shot. 1 = every shot.", 1, 20)
local cvImpacts = CreateConVar("ngl_fx_impacts", "60", FCVAR_ARCHIVE,
	"Most NGL bullet impact effects (sparks, dust, blood, decals) a second further than ngl_fx_near from every player. 0 = no cap.", 0, 10000)
local cvMuzzle = CreateConVar("ngl_fx_muzzle_range", "4000", FCVAR_ARCHIVE,
	"NGL muzzle flash effects are only sent to players this close. 0 = everyone who can see it.", 0, 50000)

local cvSounds = CreateConVar("ngl_fx_sounds", "40", FCVAR_ARCHIVE,
	"Most NGL NPC sounds a second further than ngl_fx_near from every player (each one goes to every client in earshot). 0 = no cap.", 0, 10000)

-- What NPCs played, for the benchmark (sv_bench.lua): totals since the map
-- started.
FX.Count = FX.Count or { sounds = 0, soundsCut = 0, events = 0, animSounds = 0, animCut = 0 }
local Count = FX.Count

local eyes, ne, eyesTick = {}, 0, -1

-- Player eye positions, once per tick.
local function players()
	local t = engine.TickCount()
	if t == eyesTick then return end
	eyesTick = t
	ne = 0
	for _, ply in ipairs(player.GetHumans()) do
		ne = ne + 1
		eyes[ne] = ply:EyePos()
	end
	for i = ne + 1, #eyes do eyes[i] = nil end
end

local function nearAPlayer(pos, rSqr)
	for i = 1, ne do
		if pos:DistToSqr(eyes[i]) < rSqr then return true end
	end
	return false
end

-- Impact tokens: refilled at ngl_fx_impacts a second, up to one second's worth.
local tokens, lastFill = 0, 0
local function takeImpact()
	local rate = cvImpacts:GetFloat()
	if rate <= 0 then return true end
	local now = CurTime()
	tokens = math.min(rate, tokens + (now - lastFill) * rate)
	lastFill = now
	if tokens >= 1 then
		tokens = tokens - 1
		return true
	end
	return false
end

local keep, cut = { effects = true }, { effects = false }
local function impactCallback(_, tr)
	local near = cvNear:GetFloat()
	if nearAPlayer(tr.HitPos, near * near) or takeImpact() then return keep end
	return cut
end

-- Sets the tracer and the impact budget on a FireBullets table for `npc`
-- shooting from `src`, and returns it.
function FX.Bullet(npc, bullet, src)
	players()
	local near = cvNear:GetFloat()
	if nearAPlayer(src, near * near) then
		bullet.Tracer = 1
		return bullet
	end
	local every = cvTracerEvery:GetInt()
	local k = (npc.NGLTracerN or 0) + 1
	npc.NGLTracerN = k
	-- Tracer = every: only the first bullet of the call gets one, so a
	-- 3-bullet burst makes one tracer. Tracer = 0: none.
	bullet.Tracer = (every <= 1 or k % every == 1) and every or 0
	if cvImpacts:GetFloat() > 0 then bullet.Callback = impactCallback end
	return bullet
end

-- Plays a muzzle flash only for players close enough to see it.
function FX.Muzzle(name, ed, pos)
	local r = cvMuzzle:GetFloat()
	if r <= 0 then
		util.Effect(name, ed)
		return
	end
	local filter = RecipientFilter()
	local rSqr = r * r
	for _, ply in ipairs(player.GetHumans()) do
		if ply:EyePos():DistToSqr(pos) < rSqr then filter:AddPlayer(ply) end
	end
	if filter:GetCount() > 0 then util.Effect(name, ed, true, filter) end
end

-- Sound tokens, like the impact ones.
local sTokens, sLastFill = 0, 0
local function takeSound(rate)
	local now = CurTime()
	sTokens = math.min(rate, sTokens + (now - sLastFill) * rate)
	sLastFill = now
	if sTokens >= 1 then
		sTokens = sTokens - 1
		return true
	end
	return false
end

-- Sounds the model's animations make by themselves (the engine plays the
-- sound events in the sequences: a fast zombie's gallop is four footsteps a
-- second): only for NPCs within ngl_fx_step_range of a player. Our own
-- sounds go through ENT:EmitSound (init.lua), which sets NGL.OwnSound.
local cvStep = CreateConVar("ngl_fx_step_range", "700", FCVAR_ARCHIVE,
	"Sounds from NGL NPCs' animations (footsteps and the like, played by the engine) are only played within this distance of a player. 0 = everywhere.", 0, 50000)

local debugUntil, debugCounts = 0, nil

hook.Add("EntityEmitSound", "NGL.SoundBudget", function(data)
	local e = data.Entity
	if not (e and e.IsNGLNPC and IsValid(e)) then return end
	local own = NGL.OwnSound == true
	Count.sounds = Count.sounds + 1
	if not own then Count.animSounds = (Count.animSounds or 0) + 1 end
	if debugCounts then
		local key = string.format("%-22s %-5s %s", e:GetClass(), own and "code" or "anim", data.OriginalSoundName or data.SoundName or "?")
		debugCounts[key] = (debugCounts[key] or 0) + 1
	end
	players()
	local pos = data.Pos or e:GetPos()
	if not own then
		local r = cvStep:GetFloat()
		if r > 0 and not nearAPlayer(pos, r * r) then
			Count.animCut = (Count.animCut or 0) + 1
			return false
		end
	end
	local rate = cvSounds:GetFloat()
	if rate <= 0 then return end
	local near = cvNear:GetFloat()
	if nearAPlayer(pos, near * near) or takeSound(rate) then return end
	Count.soundsCut = Count.soundsCut + 1
	return false
end)

-- ngl_debug_sounds [seconds]: counts every NGL NPC sound for a few seconds
-- (5) and prints the most played ones a second: class, who made it (our
-- code, or the model's animation), and the sound.
concommand.Add("ngl_debug_sounds", function(ply, _, args)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end
	local secs = math.Clamp(tonumber(args[1] or "") or 5, 1, 60)
	local function say(msg)
		print(msg)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
	end
	debugCounts = {}
	say(string.format("[NGL] Counting NPC sounds for %d s...", secs))
	timer.Create("NGL.DebugSounds", secs, 1, function()
		local counts = debugCounts or {}
		debugCounts = nil
		local list = {}
		for k, n in pairs(counts) do list[#list + 1] = { k = k, n = n } end
		table.sort(list, function(a, b) return a.n > b.n end)
		say("[NGL] NPC sounds a second (class, made by, sound):")
		for i = 1, math.min(#list, 15) do
			say(string.format("  %7.1f  %s", list[i].n / secs, list[i].k))
		end
		if #list == 0 then say("  none") end
	end)
end)
