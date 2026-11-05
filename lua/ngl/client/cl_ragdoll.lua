-- Death ragdolls on this client.
--
-- A dead NGL NPC turns into a client-side ragdoll (ENT:Draw, cl_init.lua):
-- physics run here, not on the server. In a long 200 NPC fight that was 50+
-- bodies at once, each simulated every frame and drawn with all its bones.
-- Now:
--   at most ngl_cl_ragdoll_max bodies; a new one removes the oldest
--   a body that has settled (ngl_cl_ragdoll_freeze seconds after death, or
--     a few seconds later whatever it does) is frozen: no more physics
--   after ngl_cl_ragdoll_time seconds it fades out and goes
--   an NPC dying further than ngl_cl_ragdoll_range from you, or one this
--     client isn't drawing anyway (too far, fog), leaves no body
-- Only this client's bodies change: the server's ragdoll setting
-- (ngl_ragdolls) and everything it does stay the same.

NGL.Ragdoll = NGL.Ragdoll or {}
local R = NGL.Ragdoll

local cvTime = CreateClientConVar("ngl_cl_ragdoll_time", "20", true, false,
	"Seconds before NGL client-side ragdolls fade out and are removed.", 0, 600)
local cvMax = CreateClientConVar("ngl_cl_ragdoll_max", "24", true, false,
	"Most NGL ragdolls on this client at once; a new one removes the oldest. 0 = no cap.", 0, 500)
local cvRange = CreateClientConVar("ngl_cl_ragdoll_range", "3000", true, false,
	"NGL NPCs dying further than this from you leave no ragdoll (they just go). 0 = any distance.", 0, 50000)
local cvFreeze = CreateClientConVar("ngl_cl_ragdoll_freeze", "3", true, false,
	"Seconds after death an NGL ragdoll that has stopped moving is frozen (no more physics). 0 = never.", 0, 60)

local FADE = 1          -- seconds of fading out at the end
local SETTLED = 12 * 12 -- every part slower than this (units/s, squared): settled
local FORCE_AFTER = 5   -- seconds after ngl_cl_ragdoll_freeze it's frozen anyway
local CHECK_EVERY = 0.25

local list = {} -- { ent, born, frozen, fade }, oldest first
local nextCheck = 0

-- Does a dying `npc` get a body on this client?
function R.Wanted(npc)
	if npc.NGLFar then return false end -- not drawn here anyway
	local r = cvRange:GetFloat()
	if r <= 0 then return true end
	local from = NGL.MainOrigin and NGL.MainOrigin() or EyePos()
	return npc:GetPos():DistToSqr(from) <= r * r
end

-- Entities can't be removed while the frame is being drawn, and new bodies
-- come from ENT:Draw: ones to go are hidden at once and removed in the
-- next Think.
local doomed = {}
local function drop(i)
	local e = list[i].ent
	table.remove(list, i)
	if IsValid(e) then
		e:SetNoDraw(true)
		doomed[#doomed + 1] = e
	end
end

-- Takes over a new client ragdoll.
function R.Add(rag)
	local max = cvMax:GetInt()
	if max > 0 then
		while #list >= max do drop(1) end
	end
	list[#list + 1] = { ent = rag, born = RealTime() }
end

function R.Count() return #list end

local function settled(e)
	for i = 0, e:GetPhysicsObjectCount() - 1 do
		local p = e:GetPhysicsObjectNum(i)
		if IsValid(p) and p:IsMotionEnabled() and p:GetVelocity():LengthSqr() > SETTLED then return false end
	end
	return true
end

local function freeze(e)
	for i = 0, e:GetPhysicsObjectCount() - 1 do
		local p = e:GetPhysicsObjectNum(i)
		if IsValid(p) then
			p:EnableMotion(false)
			p:Sleep()
		end
	end
end

hook.Add("Think", "NGL.Ragdolls", function()
	for i = #doomed, 1, -1 do
		local e = doomed[i]
		doomed[i] = nil
		if IsValid(e) then e:Remove() end
	end
	local n = #list
	if n == 0 then return end
	local now = RealTime()
	local check = now >= nextCheck
	if check then nextCheck = now + CHECK_EVERY end
	local life = cvTime:GetFloat()
	local fz = cvFreeze:GetFloat()
	local i = 1
	while i <= #list do
		local r = list[i]
		local e = r.ent
		if not IsValid(e) then
			table.remove(list, i)
		else
			local age = now - r.born
			if age >= life then
				-- Fading out over FADE seconds, then gone.
				if not r.fade then
					r.fade = now
					e:SetRenderMode(RENDERMODE_TRANSCOLOR)
				end
				local a = 1 - (now - r.fade) / FADE
				if a <= 0 then
					drop(i)
					i = i - 1
				else
					local c = e:GetColor()
					c.a = math.floor(255 * a)
					e:SetColor(c)
				end
			elseif check and not r.frozen and fz > 0 and age >= fz
				and (age >= fz + FORCE_AFTER or settled(e)) then
				r.frozen = true
				freeze(e)
			end
			i = i + 1
		end
	end
end)

-- ngl_cl_ragdoll_clear: removes every NGL body on this client now.
concommand.Add("ngl_cl_ragdoll_clear", function()
	for i = #list, 1, -1 do drop(i) end
end)
