include("shared.lua")

local cvRagdollTime = CreateClientConVar("ngl_cl_ragdoll_time", "20", true, false,
	"Seconds before NGL client-side ragdolls are removed.", 0, 600)
local cvWeaponRange = CreateClientConVar("ngl_cl_weapon_range", "4000", true, false,
	"NGL NPC weapons are drawn within this distance (a bonemerged weapon costs about as much to draw as a second NPC). 0 = always.", 0, 50000)

function ENT:Draw()
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
			self:NGLRemoveBodyModel()
		end
		return
	end

	self:DrawModel()
	if self:GetNGLBody() ~= "" or self.NGLBodyEnt then self:NGLDrawBody() end
	local top = self:GetNGLRope()
	if top ~= vector_origin then
		self:NGLDrawRope(top)
	elseif self.NGLRopeBounds then
		-- Landed: back to the model's own render bounds.
		self.NGLRopeBounds = nil
		local mins, maxs = self:GetModelBounds()
		if mins then self:SetRenderBounds(mins, maxs) end
	end

	-- Weapon is a client-only bonemerged model: no extra server entity.
	-- Skipped far away, where it's a few pixels but still costs a bone merge.
	local wr = cvWeaponRange:GetFloat()
	if self.WeaponModel and (wr <= 0 or EyePos():DistToSqr(self:GetPos()) < wr * wr) then
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

-- Roping down, the server plays the rope animations on an animation-only
-- model (ENT.RappelAnimModel, no mesh of its own): draw the NPC's own model
-- on it, bone-merged, until it lands.
function ENT:NGLDrawBody()
	local body = self:GetNGLBody()
	local bm = self.NGLBodyEnt
	if body == "" then self:NGLRemoveBodyModel() return end
	if IsValid(bm) and bm:GetModel() ~= body then self:NGLRemoveBodyModel() bm = nil end
	if not IsValid(bm) then
		bm = ClientsideModel(body, RENDERGROUP_OPAQUE)
		if not IsValid(bm) then return end
		bm:SetNoDraw(true)
		self.NGLBodyEnt = bm
	end
	if bm:GetParent() ~= self then
		bm:SetParent(self)
		bm:AddEffects(EF_BONEMERGE)
	end
	bm:SetSkin(self:GetSkin())
	bm:DrawModel()
end

function ENT:NGLRemoveBodyModel()
	if IsValid(self.NGLBodyEnt) then self.NGLBodyEnt:Remove() end
	self.NGLBodyEnt = nil
end

-- The rope, with GMod's rope texture: from where it's tied at the top of the
-- ledge down through the left hand, and a little loose end below it.
local ROPE_MAT = Material("cable/rope")
local ROPE_COLOR = Color(255, 255, 255)
local ROPE_WIDTH = 2
local ROPE_TAIL = Vector(0, 0, 48)

function ENT:NGLDrawRope(top)
	local hand
	local bone = self:LookupBone("ValveBiped.Bip01_L_Hand")
	if bone then hand = self:GetBonePosition(bone) end
	if not hand or hand == self:GetPos() then hand = self:GetPos() + Vector(0, 0, 60) end
	local tail = hand - ROPE_TAIL
	-- It reaches far above the NPC: keep it drawn while the top is in view.
	self:SetRenderBoundsWS(Vector(math.min(top.x, tail.x) - 32, math.min(top.y, tail.y) - 32, tail.z - 80),
		Vector(math.max(top.x, tail.x) + 32, math.max(top.y, tail.y) + 32, top.z + 16))
	self.NGLRopeBounds = true
	render.SetMaterial(ROPE_MAT)
	local len = top:Distance(hand)
	render.DrawBeam(top, hand, ROPE_WIDTH, 0, len / 32, ROPE_COLOR)
	render.DrawBeam(hand, tail, ROPE_WIDTH, len / 32, (len + 48) / 32, ROPE_COLOR)
end

function ENT:OnRemove()
	self:NGLRemoveWeaponModel()
	self:NGLRemoveBodyModel()
end

-- Leaving this client's view (PVS): drop the weapon model; Draw makes a fresh
-- one when the NPC is visible again.
hook.Add("NotifyShouldTransmit", "NGL.WeaponModel", function(ent, transmit)
	if not transmit and ent.IsNGLNPC and ent.NGLRemoveWeaponModel then
		ent:NGLRemoveWeaponModel()
		ent:NGLRemoveBodyModel()
	end
end)
