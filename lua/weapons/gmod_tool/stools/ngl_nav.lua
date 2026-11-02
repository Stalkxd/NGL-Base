-- NGL Nav Editor: fix the NGL nav grid by hand, like any other tool.
--   Area mode:  left click adds walkable area round the spot (flood-filled
--               within the radius), right click removes the grid there.
--   Link mode:  left click where the jump starts, then left click where it
--               lands: NPCs jump down there, up onto it (short ones), or
--               across, if it's level. Right click removes links near the spot.
--   Climb mode: left click the bottom, then the top (or the other way): NPCs
--               that climb (ENT.Climb) go up and down there. Right click
--               removes links near the spot.
--   Reload:     undo the last edit.
-- The grid round you is drawn while the tool is out: open floor as filled
-- squares, narrower walkable places as blue lines, yellow drops, orange
-- jumps up, green gap jumps, purple climbs. Superadmins only. Edits are
-- saved per map and survive regenerating the grid (see sv_nav_edit.lua).
TOOL.Category = "NGL Base"
TOOL.Name = "#tool.ngl_nav.name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.ClientConVar["mode"] = "area"
TOOL.ClientConVar["radius"] = "160"

TOOL.Information = {
	{ name = "left" },
	{ name = "right" },
	{ name = "reload" },
}

if CLIENT then
	language.Add("tool.ngl_nav.name", "NGL Nav Editor")
	language.Add("tool.ngl_nav.desc", "Edit where NGL NPCs can walk and jump")
	language.Add("tool.ngl_nav.left", "Area: add walkable area. Link / Climb: set the start, then the other end")
	language.Add("tool.ngl_nav.right", "Area: remove area. Link / Climb: remove links here")
	language.Add("tool.ngl_nav.reload", "Undo last edit")
end

local function use(self, trace, button)
	if CLIENT then return true end
	local ply = self:GetOwner()
	if not (NGL and NGL.Nav and NGL.Nav.ToolUse) then return false end
	local mode = self:GetClientInfo("mode")
	if mode ~= "link" and mode ~= "climb" then mode = "area" end
	local radius = math.Clamp(self:GetClientNumber("radius", 160), 16, 1024)
	return NGL.Nav.ToolUse(ply, mode, button, trace.HitPos, radius)
end

function TOOL:LeftClick(trace) return use(self, trace, "left") end
function TOOL:RightClick(trace) return use(self, trace, "right") end
function TOOL:Reload(trace) return use(self, trace, "reload") end

if CLIENT then
	-- Ask the server for the grid round us about once a second while out.
	function TOOL:Think()
		local now = CurTime()
		if now >= (self.NGLNextView or 0) then
			self.NGLNextView = now + 1
			net.Start("ngl_nav_view")
			net.SendToServer()
			if NGL and NGL.NavView then NGL.NavView.until_ = now + 2 end
		end
	end

	function TOOL.BuildCPanel(panel)
		panel:Help("Fix where NGL NPCs walk. The grid is made on its own for maps without one (ngl_nav_auto 0 turns that off). Edits are saved per map and kept when the grid is made again.")
		local combo = panel:ComboBox("Mode", "ngl_nav_mode")
		combo:AddChoice("Walkable area (add / remove)", "area")
		combo:AddChoice("Jump links (down, up, across gaps)", "link")
		combo:AddChoice("Climb links (for climbing NPCs)", "climb")
		panel:NumSlider("Radius", "ngl_nav_radius", 16, 1024, 0)
		panel:Help("Filled squares: open floor, NPCs walk straight across. Blue lines: narrower walkable places. Yellow: jump down. Orange: jump up. Green: jump across. Purple: climb.")
		panel:Button("Generate the grid again", "ngl_nav_generate")
		panel:Button("Remove all my edits", "ngl_nav_edit_clear")
		panel:Help("Console: ngl_nav_auto 0/1, ngl_nav_drops 0/1, ngl_nav_max_drop, ngl_nav_max_up, ngl_nav_spacing, ngl_nav_info")
	end
end
