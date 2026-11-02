-- NGL Nav Editor: fix the NGL nav grid by hand, like any other tool.
--   Area mode:  left click adds walkable area round the spot (flood-filled
--               within the radius), right click removes the grid there.
--   Link mode:  left click on a ledge, then left click where to land: NPCs
--               jump down there (or across, if it's level). Right click
--               removes jump links near the spot.
--   Reload:     undo the last edit.
-- The grid round you is drawn while the tool is out: blue walkable links,
-- yellow ledge drops, green gap jumps. Superadmins only. Edits are saved
-- per map and survive regenerating the grid (see sv_nav_edit.lua).
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
	language.Add("tool.ngl_nav.left", "Area: add walkable area. Link: set jump start, then landing")
	language.Add("tool.ngl_nav.right", "Area: remove area. Link: remove jump links here")
	language.Add("tool.ngl_nav.reload", "Undo last edit")
end

local function use(self, trace, button)
	if CLIENT then return true end
	local ply = self:GetOwner()
	if not (NGL and NGL.Nav and NGL.Nav.ToolUse) then return false end
	local mode = self:GetClientInfo("mode") == "link" and "link" or "area"
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
		combo:AddChoice("Jump links (ledge drops, gaps)", "link")
		panel:NumSlider("Radius", "ngl_nav_radius", 16, 1024, 0)
		panel:Help("Blue: walkable. Yellow: drop down a ledge (small ones: everyone, big ones: Combine rappel). Green: jump across.")
		panel:Button("Generate the grid again", "ngl_nav_generate")
		panel:Button("Remove all my edits", "ngl_nav_edit_clear")
		panel:Help("Console: ngl_nav_auto 0/1, ngl_nav_drops 0/1, ngl_nav_max_drop, ngl_nav_spacing, ngl_nav_info")
	end
end
