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
		end
		return
	end

	self:DrawModel()

	-- Weapon is a client-only bonemerged model: no extra server entity.
	-- Skipped far away, where it's a few pixels but still costs a bone merge.
	local wr = cvWeaponRange:GetFloat()
	if self.WeaponModel and (wr <= 0 or EyePos():DistToSqr(self:GetPos()) < wr * wr) then
		local wm = self.NGLWeaponEnt
		if not IsValid(wm) then
			wm = ClientsideModel(self.WeaponModel, RENDERGROUP_OPAQUE)
			if IsValid(wm) then
				wm:SetParent(self)
				wm:AddEffects(EF_BONEMERGE)
				wm:SetNoDraw(true)
				self.NGLWeaponEnt = wm
			end
		end
		if IsValid(wm) then wm:DrawModel() end
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
