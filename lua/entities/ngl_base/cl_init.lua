include("shared.lua")

-- Death ragdolls: ngl_cl_ragdoll_* (cl_ragdoll.lua).
local cvWeaponRange = CreateClientConVar("ngl_cl_weapon_range", "2500", true, false,
	"NGL NPC weapons are drawn within this distance (a bonemerged weapon costs about as much to draw as a second NPC). 0 = always.", 0, 50000)
-- Sent to the server (userinfo): it stops sending this client NPCs a bit
-- beyond this range (ngl_net_cull, sv_transmit.lua).
local cvDrawRange = CreateClientConVar("ngl_cl_draw_range", "6000", true, true,
	"NGL NPCs further than this aren't drawn at all (vehicles twice as far). In map fog they also stop where the fog is solid. The server also stops sending you NPCs a bit beyond it. 0 = always drawn.", 0, 50000)
local cvLodRange = CreateClientConVar("ngl_cl_lod_range", "2500", true, false,
	"NGL NPCs further than this are drawn with their model's lowest level of detail (fewest polygons). 0 = the engine picks as usual.", 0, 50000)
local cvShadowRange = CreateClientConVar("ngl_cl_shadow_range", "2000", true, false,
	"NGL NPCs further than this cast no shadow (each shadow is drawn again into a texture every frame). 0 = always.", 0, 50000)
local cvFlexRange = CreateClientConVar("ngl_cl_flex_range", "1000", true, false,
	"NGL NPCs further than this get no facial animation (flexes: faces, mouths, eyes of rebels and citizens). 0 = always.", 0, 50000)
local cvOcclusion = CreateClientConVar("ngl_cl_occlusion", "1", true, false,
	"1 = NGL NPCs hidden behind walls or props aren't drawn (the graphics card tells us, a frame late, whether any of the NPC would show). 0 = off.", 0, 1)
local cvOcclusionNear = CreateClientConVar("ngl_cl_occlusion_near", "600", true, false,
	"NGL NPCs closer than this are always drawn, even when they seem hidden (no popping right next to you).", 0, 50000)
local cvEventRange = CreateClientConVar("ngl_cl_event_range", "1500", true, false,
	"NGL NPCs further than this skip their animations' client events (footstep sounds, dust, shells): each one is a sound or an effect made on this client. 0 = always.", 0, 50000)
local cvDecalRange = CreateClientConVar("ngl_cl_decal_range", "1000", true, false,
	"Blood and bullet decals on NGL NPCs further than this, or out of your sight, are cleared (each decal on a model draws the model again). 0 = never cleared.", 0, 50000)
local cvReflectRange = CreateClientConVar("ngl_cl_reflection_range", "1500", true, false,
	"NGL NPCs further than this from you aren't drawn in water reflections and other extra views (cameras, mirrors), which draw everything again. 0 = always.", 0, 50000)

-- Where the main view is drawn from this frame. Water reflections, cameras
-- and mirrors draw the world again from somewhere else in the same frame;
-- Draw tells them apart by the eye position.
local mainOrigin
hook.Add("RenderScene", "NGL.MainView", function(origin) mainOrigin = origin end)
local function inMainView()
	return mainOrigin == nil or EyePos():DistToSqr(mainOrigin) < 4
end
NGL.InMainView = inMainView -- the far-NPC pictures are only drawn there (cl_impostor.lua)
NGL.MainOrigin = function() return mainOrigin end -- ragdoll range (cl_ragdoll.lua)

-- The settings, read once a frame instead of by every NPC's Draw: ranges
-- squared (math.huge for 0 = off). The fog is read by the first NPC drawn
-- in the main view each frame, where the engine has set it up.
local HUGE = math.huge
local Set = { frame = -1 }
local function sq(cv)
	local r = cv:GetFloat()
	return r > 0 and r * r or HUGE
end
local function settings()
	local f = FrameNumber()
	if Set.frame == f then return Set end
	Set.frame = f
	-- Steady FPS (cl_quality.lua): detail ranges shrink by this when the
	-- frame rate is below ngl_cl_fps_target. 1 = as set.
	local q = NGL.ClScale or 1
	local q2 = q * q
	Set.weapon = sq(cvWeaponRange) * q2
	Set.draw = sq(cvDrawRange)
	Set.lod = sq(cvLodRange) * q2
	Set.shadow = sq(cvShadowRange) * q2
	Set.flex = sq(cvFlexRange) * q2
	Set.reflect = sq(cvReflectRange)
	Set.event = sq(cvEventRange)
	local dr = cvDecalRange:GetFloat()
	Set.decal = dr > 0 and dr * dr * q2 or nil
	Set.occlusion = cvOcclusion:GetBool()
	local near = cvOcclusionNear:GetFloat()
	Set.occlusionNear = near * near
	Set.fog = nil
	return Set
end
local function fogEndSqr(S)
	local fog = S.fog
	if fog == nil then
		fog = HUGE
		if render.GetFogMode() == MATERIAL_FOG_LINEAR then
			local _, fogEnd = render.GetFogDistances()
			if fogEnd and fogEnd > 0 then fog = fogEnd * fogEnd end
		end
		S.fog = fog
	end
	return fog
end

-- Each switch below goes off a tenth further out than it comes back on
-- (squared: 1.21), so an NPC walking along the edge doesn't flip every frame.
local OUT = 1.21
local function beyond(d, rSqr, was)
	if was then return d > rSqr end
	return d > rSqr * OUT
end

-- Counters for the client benchmark (cl_bench.lua): what Draw did this frame.
NGL.ClStats = NGL.ClStats or { drawn = 0, occluded = 0, far = 0, impostor = 0, budget = 0 }
local Stats = NGL.ClStats
Stats.events, Stats.eventsCut, Stats.sounds = Stats.events or 0, Stats.eventsCut or 0, Stats.sounds or 0
Stats.decalClears = Stats.decalClears or 0
Stats.drawLua = Stats.drawLua or 0     -- seconds of our Lua in NPC Draw this frame (main view)
Stats.drawModel = Stats.drawModel or 0 -- seconds in DrawModel for full models and weapons (the engine's part)

-- Level of detail on this client, from near to far:
--   full     the model as the engine picks it, with weapon and shadow
--   low      beyond ngl_cl_flex_range no facial animation; beyond
--            ngl_cl_shadow_range no shadow; beyond ngl_cl_lod_range the
--            model's lowest LOD (Source models carry up to 8 LODs; one
--            without them just stays as it is); beyond ngl_cl_weapon_range
--            no weapon
--   hidden   beyond ngl_cl_draw_range, or past the end of the map's fog,
--            not drawn: no bones set up, nothing rendered
--   occluded closer, but behind a wall or a prop (ngl_cl_occlusion): not
--            drawn either until any of it shows again
--   picture  beyond ngl_cl_impostor_range a flat picture of the NPC instead
--            of the model (cl_impostor.lua)
--   not sent a bit beyond ngl_cl_draw_range the server stops sending the
--            NPC to this client at all (ngl_net_cull, sv_transmit.lua)
-- Only this client's drawing changes. The server still runs every NPC, and
-- an NPC that isn't drawn can still shoot you and be shot.
local LOWEST_LOD = 7 -- clamped by the engine to the model's own last LOD

-- ngl_debug_parts' client-side parts (cl_parts.lua): nil unless testing.
local function clOff(self, key)
	local O = NGL.ClOff
	return O ~= nil and O[key] == true and (O.class == nil or self:GetClass() == O.class)
end

function ENT:NGLDrawLevel(d, S)
	local forceLow = NGL.ClOff ~= nil and clOff(self, "lowlod")
	-- Shadow
	local noShadow = forceLow or self.NGLImp == true or self.NGLShared == true or beyond(d, S.shadow, self.NGLNoShadow)
	if noShadow ~= (self.NGLNoShadow or false) then
		self.NGLNoShadow = noShadow
		if noShadow then self:DestroyShadow() else self:CreateShadow() end
	end
	-- Model LOD
	local low = forceLow or beyond(d, S.lod, self.NGLLowLod)
	if low ~= (self.NGLLowLod or false) then
		self.NGLLowLod = low
		self:SetLOD(low and LOWEST_LOD or -1)
	end
	-- Facial animation (models with flexes only)
	local nf = self.NGLFlexes
	if nf == nil then
		nf = (self.GetFlexNum and self:GetFlexNum() or 0) > 0 and self.SetFlexScale ~= nil
		self.NGLFlexes = nf
	end
	if nf then
		local noFlex = beyond(d, S.flex, self.NGLNoFlex)
		if noFlex ~= (self.NGLNoFlex or false) then
			self.NGLNoFlex = noFlex
			self:SetFlexScale(noFlex and 0 or 1)
		end
	end
	-- Not drawn at all
	local r = S.draw
	if self.IsVehicleNPC then r = r * 4 end -- twice as far
	if beyond(d, r, self.NGLFar) then return false end
	return d <= fogEndSqr(S)
end

-- Occlusion: one pixel-visibility query per NPC (util.PixelVisible). The
-- card draws a small invisible sprite at the NPC's middle against what's
-- already on screen and reports, a frame later, how much of it showed. 0 for
-- a short while = hidden behind something: no bones set up, nothing drawn.
-- Seen again = drawn at once. A new NPC counts as seen until its first
-- answer comes back. The query is only made in the main view, drawn to the
-- screen: water reflections and refractions are drawn first, into their own
-- textures, and a query there tested the NPC against the wrong picture, so
-- NPCs in plain view vanished. Elsewhere the last answer is kept.
-- The sprite is put where the NPC will be LEAD seconds from now, from how it
-- moved since the last frame: the answer comes a frame late, so a fast
-- zombie running out from behind a wall would otherwise show up already in
-- front of you. Its body sticking out counts too: the sprite is as big as
-- the NPC.
local HIDE_AFTER = 0.15 -- seconds of 0 before an NPC counts as hidden
local LEAD = 0.3        -- seconds ahead the sprite is put
local LEAD_MAX = 250    -- units ahead at most
local SHADOW_FLAGS = bit.bor(STUDIO_SHADOWTEXTURE or 0, STUDIO_SHADOWDEPTHTEXTURE or 0)

local function shadowPass(flags)
	return flags ~= nil and SHADOW_FLAGS ~= 0 and bit.band(flags, SHADOW_FLAGS) ~= 0
end

function ENT:NGLOccluded(d, S, pos)
	if not S.occlusion then
		self.NGLHidden = false
		return false
	end
	local now = RealTime()
	if d < S.occlusionNear then
		self.NGLHidden = false
		self.NGLSeenAt = now
		return false
	end
	if mainOrigin == nil or render.GetRenderTarget() ~= nil then return self.NGLHidden or false end
	local frame = FrameNumber()
	if self.NGLVisFrame == frame then return self.NGLHidden or false end
	self.NGLVisFrame = frame
	local h = self.NGLVisHandle
	if not h then
		h = util.GetPixelVisibleHandle()
		self.NGLVisHandle = h
		self.NGLSeenAt = now
	end
	-- No new vectors here (it runs for every NPC every frame, and each new
	-- vector is garbage the collector has to clear): the middle is the
	-- position plus the box's middle height, read once, and the lead is
	-- worked out in numbers into a vector kept on the NPC.
	local r = self.NGLVisR
	local cz = self.NGLVisCZ
	if not r then
		r = math.max(16, self:BoundingRadius() * 0.8)
		local mn, mx = self:OBBMins(), self:OBBMaxs()
		cz = (mn.z + mx.z) * 0.5
		self.NGLVisR, self.NGLVisCZ = r, cz
	end
	local x, y, z = pos.x, pos.y, pos.z + cz
	local lx, ly, lz, lastT = self.NGLVisLX, self.NGLVisLY, self.NGLVisLZ, self.NGLVisLastT
	self.NGLVisLX, self.NGLVisLY, self.NGLVisLZ, self.NGLVisLastT = x, y, z, now
	local ax, ay, az = x, y, z
	if lx and now > lastT and now - lastT < 0.25 then
		local k = LEAD / (now - lastT)
		local dx, dy, dz = (x - lx) * k, (y - ly) * k, (z - lz) * k
		local len = math.sqrt(dx * dx + dy * dy + dz * dz)
		if len > LEAD_MAX then
			local f = LEAD_MAX / len
			dx, dy, dz = dx * f, dy * f, dz * f
		end
		ax, ay, az = x + dx, y + dy, z + dz
	end
	local at = self.NGLVisAt
	if not at then
		at = Vector()
		self.NGLVisAt = at
	end
	at:SetUnpacked(ax, ay, az)
	if util.PixelVisible(at, r, h) > 0 then
		self.NGLSeenAt = now
		self.NGLHidden = false
	else
		self.NGLHidden = now - (self.NGLSeenAt or now) > HIDE_AFTER
	end
	return self.NGLHidden
end

-- Decals on the model: every bullet that hits an NPC leaves blood on it,
-- and each decal draws the model once more, so after a long fight an NPC
-- near you was drawn dozens of times a frame. They are cleared where
-- nobody sees them go: further than ngl_cl_decal_range, hidden behind a
-- wall, drawn as a picture, or when it comes back into view after being
-- out of it (behind you) for a moment. At most every DECAL_EVERY seconds an
-- NPC. Close and in view they stay.
local DECAL_EVERY = 2
local DECAL_AWAY = 0.5 -- s out of view before the decals go when it's back
-- Cleared in the next Think, not in the middle of drawing.
local decalQueue = {}
local function clearDecals(self, S, now)
	if not S.decal or now < (self.NGLDecalT or 0) then return end
	self.NGLDecalT = now + DECAL_EVERY
	decalQueue[#decalQueue + 1] = self
end
hook.Add("Think", "NGL.ClearDecals", function()
	local n = #decalQueue
	if n == 0 then return end
	for i = 1, n do
		local e = decalQueue[i]
		decalQueue[i] = nil
		if IsValid(e) then
			e:RemoveAllDecals()
			Stats.decalClears = Stats.decalClears + 1
		end
	end
end)

-- ngl_debug_parts "clanim": the server has stopped advancing this NPC's
-- animation, so this client plays it itself, once a frame before it's
-- drawn: from the cycle it had when its animation started, at the
-- playback rate the server sends, looping or stopping at the end as the
-- animation says. Set after the engine's interpolation, so it's what's
-- drawn (and what the picture of a far NPC is picked by).
local loops = {} -- [model .. sequence] = true when it loops
local function seqLoops(self, seq)
	local k = self:GetModel() .. "#" .. seq
	local l = loops[k]
	if l == nil then
		local info = self:GetSequenceInfo(seq)
		l = info ~= nil and info.flags ~= nil and bit.band(info.flags, 1) ~= 0
		loops[k] = l
	end
	return l
end
function ENT:NGLClientCycle()
	local f = FrameNumber()
	if self.NGLClFrame == f then return end
	self.NGLClFrame = f
	local seq = self:GetSequence()
	local now = CurTime()
	if self.NGLClSeq ~= seq or not self.NGLClT then
		self.NGLClSeq, self.NGLClCycle, self.NGLClT = seq, self:GetCycle(), now
		return
	end
	local dur = self:SequenceDuration(seq)
	local dt = now - self.NGLClT
	self.NGLClT = now
	if dur and dur > 0 and dt > 0 then
		local c = self.NGLClCycle + dt * self:GetPlaybackRate() / dur
		if seqLoops(self, seq) then c = c % 1 elseif c > 1 then c = 1 end
		self.NGLClCycle = c
	end
	self:SetCycle(self.NGLClCycle)
	self:InvalidateBoneCache()
end

function ENT:Draw(flags)
	if self:GetNGLDead() then
		if not self.NGLRagdolled then
			-- Once: a body (cl_ragdoll.lua keeps their number down), unless
			-- it died too far away to bother.
			self.NGLRagdolled = true
			self:NGLRemoveWeaponModel()
			local R = NGL.Ragdoll
			if not R or R.Wanted(self) then
				local rag = self:BecomeRagdollOnClient()
				if IsValid(rag) and R then R.Add(rag) end
			end
		end
		return
	end

	if NGL.ClOff ~= nil then -- ngl_debug_parts
		if clOff(self, "draw") then return end
		if clOff(self, "clanim") then self:NGLClientCycle() else self.NGLClT = nil end
	end
	local shadow = shadowPass(flags)
	if shadow then
		-- Into its shadow texture: only for NPCs that cast one and show.
		if self.NGLNoShadow or self.NGLHidden or self.NGLFar or self.NGLImp or self.NGLShared then return end
		self:DrawModel()
		return
	end
	local S = settings()
	if not inMainView() then
		-- A water reflection, a camera or a mirror: only NPCs near you, and
		-- no level-of-detail switching (that follows the main view).
		if self.NGLFar or (mainOrigin and self:GetPos():DistToSqr(mainOrigin) > S.reflect) then return end
		self:DrawModel()
		if IsValid(self.NGLWeaponEnt) and self.NGLWeaponEnt:GetParent() == self then self.NGLWeaponEnt:DrawModel() end
		return
	end

	local t0 = SysTime() -- Lua time of NPC drawing, for the benchmark
	-- The main view's eye, read once a frame (EyePos makes a new vector).
	local eye = mainOrigin or EyePos()
	local pos = self:GetPos()
	local d = eye:DistToSqr(pos)
	local now = RealTime()
	local away = now - (self.NGLViewT or 0) > DECAL_AWAY
	self.NGLViewT = now
	self.NGLFar = not self:NGLDrawLevel(d, S)
	if self.NGLFar then
		if self.NGLWeaponEnt then self:NGLRemoveWeaponModel() end
		Stats.far = Stats.far + 1
		clearDecals(self, S, now)
		Stats.drawLua = Stats.drawLua + (SysTime() - t0)
		return
	end
	local Imp = NGL.Impostor
	if not self.NGLAheadDone and Imp and Imp.Ahead then
		-- First time within draw range (seen or behind a wall): its
		-- pictures are made ahead, a few a frame.
		self.NGLAheadDone = true
		Imp.Ahead(self)
	end
	-- Hidden behind a wall: skip the model and the weapon, keep the weapon
	-- model for when it comes out.
	if self:NGLOccluded(d, S, pos) then
		Stats.occluded = Stats.occluded + 1
		clearDecals(self, S, now)
		Stats.drawLua = Stats.drawLua + (SysTime() - t0)
		return
	end
	-- Far: a flat picture of it instead (cl_impostor.lua), once one is made.
	if Imp and Imp.Draw(self, d, pos, eye) then
		Stats.impostor = Stats.impostor + 1
		self.NGLShared = false
		clearDecals(self, S, now)
		Stats.drawLua = Stats.drawLua + (SysTime() - t0)
		return
	end
	-- Mid-range in a crowd: drawn with a pose shared with every NPC playing
	-- the same moment of the same animation (cl_crowd.lua), when that's on.
	local Crowd = NGL.Crowd
	if Crowd and Crowd.Draw(self, d, pos) then
		self.NGLShared = true
		Stats.shared = (Stats.shared or 0) + 1
		clearDecals(self, S, now)
		Stats.drawLua = Stats.drawLua + (SysTime() - t0)
		return
	end
	self.NGLShared = false

	if away or (S.decal and d > S.decal) then clearDecals(self, S, now) end
	-- From here on it's mostly the engine's work (bones, skinning, drawing):
	-- timed apart from our Lua.
	local t1 = SysTime()
	Stats.drawLua = Stats.drawLua + (t1 - t0)
	self:DrawModel()
	Stats.drawn = Stats.drawn + 1

	-- Weapon is a client-only bonemerged model: no extra server entity.
	-- Skipped far away, where it's a few pixels but still costs a bone merge.
	-- Made when the NPC comes within ngl_cl_weapon_range, freed a tenth
	-- further out, so one on the edge isn't made and freed over and over.
	local wm = self.NGLWeaponEnt
	if self.WeaponModel and not beyond(d, S.weapon, wm == nil) then
		if not IsValid(wm) then
			wm = ClientsideModel(self.WeaponModel, RENDERGROUP_OPAQUE)
			if IsValid(wm) then
				wm:SetNoDraw(true)
				self.NGLWeaponEnt = wm
			end
		end
		if IsValid(wm) then
			-- The parent link breaks when the NPC goes out of view (dormant) and
			-- comes back; re-attach, or the weapon stays invisible.
			if wm:GetParent() ~= self then
				wm:SetParent(self)
				wm:AddEffects(EF_BONEMERGE)
			end
			wm:DrawModel()
		end
	elseif wm then
		-- Out of weapon range: free it; it's made again when we come closer.
		self:NGLRemoveWeaponModel()
	end
	Stats.drawModel = Stats.drawModel + (SysTime() - t1)
end

-- The model's client-side animation events (footsteps, sounds, effects),
-- which the engine plays for every NPC this client has, drawn or not. Far
-- ones are skipped (returning true stops the event).
function ENT:FireAnimationEvent(pos, ang, event, name)
	Stats.events = Stats.events + 1
	local S = settings()
	if S.event < HUGE and EyePos():DistToSqr(self:GetPos()) > S.event then
		Stats.eventsCut = Stats.eventsCut + 1
		return true
	end
end

-- Sounds this client makes for NGL NPCs itself (from those events), for the
-- benchmark.
hook.Add("EntityEmitSound", "NGL.ClSounds", function(data)
	local e = data.Entity
	if e and e.IsNGLNPC then Stats.sounds = Stats.sounds + 1 end
end)

function ENT:NGLRemoveWeaponModel()
	if IsValid(self.NGLWeaponEnt) then
		self.NGLWeaponEnt:Remove()
		self.NGLWeaponEnt = nil
	end
end

function ENT:OnRemove()
	self:NGLRemoveWeaponModel()
end

-- Leaving this client's view (PVS): drop the weapon model; Draw makes a fresh
-- one when the NPC is visible again.
hook.Add("NotifyShouldTransmit", "NGL.WeaponModel", function(ent, transmit)
	if not transmit and ent.IsNGLNPC and ent.NGLRemoveWeaponModel then ent:NGLRemoveWeaponModel() end
end)
