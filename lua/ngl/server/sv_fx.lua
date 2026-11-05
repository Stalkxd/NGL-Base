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
