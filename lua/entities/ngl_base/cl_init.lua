include("shared.lua")

local cvRagdollTime = CreateClientConVar("ngl_cl_ragdoll_time", "20", true, false,
	"Seconds before NGL client-side ragdolls are removed.", 0, 600)
local cvWeaponRange = CreateClientConVar("ngl_cl_weapon_range", "4000", true, false,
	"NGL NPC weapons are drawn within this distance (a bonemerged weapon costs about as much to draw as a second NPC). 0 = always.", 0, 50000)
-- Sent to the server (userinfo): it stops sending this client NPCs a bit
-- beyond this range (ngl_net_cull, sv_transmit.lua).
local cvDrawRange = CreateClientConVar("ngl_cl_draw_range", "6000", true, true,
	"NGL NPCs further than this aren't drawn at all (vehicles twice as far). In map fog they also stop where the fog is solid. The server also stops sending you NPCs a bit beyond it. 0 = always drawn.", 0, 50000)
local cvLodRange = CreateClientConVar("ngl_cl_lod_range", "2500", true, false,
	"NGL NPCs further than this are drawn with their model's lowest level of detail (fewest polygons). 0 = the engine picks as usual.", 0, 50000)
local cvShadowRange = CreateClientConVar("ngl_cl_shadow_range", "2000", true, false,
	"NGL NPCs further than this cast no shadow (each shadow is drawn again into a texture every frame). 0 = always.", 0, 50000)
local cvOcclusion = CreateClientConVar("ngl_cl_occlusion", "1", true, false,
	"1 = NGL NPCs hidden behind walls or props aren't drawn (the graphics card tells us, a frame late, whether any of the NPC would show). 0 = off.", 0, 1)
local cvOcclusionNear = CreateClientConVar("ngl_cl_occlusion_near", "600", true, false,
	"NGL NPCs closer than this are always drawn, even when they seem hidden (no popping right next to you).", 0, 50000)

-- Counters for the client benchmark (cl_bench.lua): what Draw did this frame.
NGL.ClStats = NGL.ClStats or { drawn = 0, occluded = 0, far = 0 }
local Stats = NGL.ClStats

-- Level of detail on this client, from near to far:
--   full     the model as the engine picks it, with weapon and shadow
--   low      beyond ngl_cl_shadow_range no shadow; beyond ngl_cl_lod_range
--            the model's lowest LOD (Source models carry up to 8 LODs; one
--            without them just stays as it is); beyond ngl_cl_weapon_range
--            no weapon
--   hidden   beyond ngl_cl_draw_range, or past the end of the map's fog,
--            not drawn: no bones set up, nothing rendered
--   occluded closer, but behind a wall or a prop (ngl_cl_occlusion): not
--            drawn either until any of it shows again
--   not sent a bit beyond ngl_cl_draw_range the server stops sending the
--            NPC to this client at all (ngl_net_cull, sv_transmit.lua)
-- Only this client's drawing changes. The server still runs every NPC, and
-- an NPC that isn't drawn can still shoot you and be shot.
local LOWEST_LOD = 7 -- clamped by the engine to the model's own last LOD
local function far(d, r) return r > 0 and d > r * r end

function ENT:NGLDrawLevel(d)
	-- Shadow
	local noShadow = far(d, cvShadowRange:GetFloat())
	if noShadow ~= (self.NGLNoShadow or false) then
		self.NGLNoShadow = noShadow
		if noShadow then self:DestroyShadow() else self:CreateShadow() end
	end
	-- Model LOD
	local low = far(d, cvLodRange:GetFloat())
	if low ~= (self.NGLLowLod or false) then
		self.NGLLowLod = low
		self:SetLOD(low and LOWEST_LOD or -1)
	end
	-- Not drawn at all
	local r = cvDrawRange:GetFloat()
	if r > 0 and self.IsVehicleNPC then r = r * 2 end
	if far(d, r) then return false end
	if render.GetFogMode() == MATERIAL_FOG_LINEAR then
		local _, fogEnd = render.GetFogDistances()
		if fogEnd and fogEnd > 0 and d > fogEnd * fogEnd then return false end
	end
	return true
end

-- Occlusion: one pixel-visibility query per NPC (util.PixelVisible). The
-- card draws a small invisible sprite at the NPC's middle against what's
-- already on screen and reports, a frame later, how much of it showed. 0 for
-- a short while = hidden behind something: no bones set up, nothing drawn.
-- Seen again = drawn at once. A new NPC counts as seen until its first
-- answer comes back. Only one query a frame per NPC (mirrors and water
-- reflections draw it again in the same frame and would confuse it).
local HIDE_AFTER = 0.15 -- seconds of 0 before an NPC counts as hidden
local SHADOW_FLAGS = bit.bor(STUDIO_SHADOWTEXTURE or 0, STUDIO_SHADOWDEPTHTEXTURE or 0)

local function shadowPass(flags)
	return flags ~= nil and SHADOW_FLAGS ~= 0 and bit.band(flags, SHADOW_FLAGS) ~= 0
end

function ENT:NGLOccluded(d, shadow)
	if not cvOcclusion:GetBool() then return false end
	if shadow then return self.NGLHidden or false end
	local near = cvOcclusionNear:GetFloat()
	local now = RealTime()
	if d < near * near then
		self.NGLHidden = false
		self.NGLSeenAt = now
		return false
	end
	local frame = FrameNumber()
	if self.NGLVisFrame == frame then return self.NGLHidden or false end
	self.NGLVisFrame = frame
	local h = self.NGLVisHandle
	if not h then
		h = util.GetPixelVisibleHandle()
		self.NGLVisHandle = h
		self.NGLSeenAt = now
	end
	local r = math.max(16, self:BoundingRadius() * 0.6)
	if util.PixelVisible(self:WorldSpaceCenter(), r, h) > 0 then
		self.NGLSeenAt = now
		self.NGLHidden = false
	else
		self.NGLHidden = now - (self.NGLSeenAt or now) > HIDE_AFTER
	end
	return self.NGLHidden
end

function ENT:Draw(flags)
	if self:GetNGLDead() then
		if not self.NGLRagdolled then
			self.NGLRagdolled = true
			local rag = self:BecomeRagdollOnClient()
			if IsValid(rag) then
				local t = cvRagdollTime:GetFloat()
				timer.Simple(t, function()
					if IsValid(rag) then rag:Remove() end
				end)
			end
			self:NGLRemoveWeaponModel()
		end
		return
	end

	local d = EyePos():DistToSqr(self:GetPos())
	local shadow = shadowPass(flags)
	if not self:NGLDrawLevel(d) then
		if self.NGLWeaponEnt then self:NGLRemoveWeaponModel() end
		if not shadow then Stats.far = Stats.far + 1 end
		return
	end
	-- Hidden behind a wall: skip the model and the weapon, keep the weapon
	-- model for when it comes out.
	if self:NGLOccluded(d, shadow) then
		if not shadow then Stats.occluded = Stats.occluded + 1 end
		return
	end

	self:DrawModel()
	if not shadow then Stats.drawn = Stats.drawn + 1 end

	-- Weapon is a client-only bonemerged model: no extra server entity.
	-- Skipped far away, where it's a few pixels but still costs a bone merge.
	local wr = cvWeaponRange:GetFloat()
	if self.WeaponModel and (wr <= 0 or d < wr * wr) then
		local wm = self.NGLWeaponEnt
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
	elseif self.NGLWeaponEnt then
		-- Out of weapon range: free it; it's made again when we come closer.
		self:NGLRemoveWeaponModel()
	end
end

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
