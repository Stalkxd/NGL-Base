-- NGL NPC Tracker: see where NGL NPCs are going and what they're doing.
--   Left click:  track the NPC you aim at (again to stop), up to 8.
--   Right click: stop tracking them all.
-- Drawn for each: where it has been (white), its path ahead (blue, jumps in
-- yellow, jumps up orange, climbs purple), where it's heading (green ring),
-- a player's move order target (pink ring), and a line of text over its
-- head (class, AI mode, order, squad, enemy, moving how). Superadmins only.
TOOL.Category = "NGL Base"
TOOL.Name = "#tool.ngl_track.name"
TOOL.Command = nil
TOOL.ConfigName = ""

TOOL.Information = {
	{ name = "left" },
	{ name = "right" },
}

if CLIENT then
	language.Add("tool.ngl_track.name", "NGL NPC Tracker")
	language.Add("tool.ngl_track.desc", "Watch where NGL NPCs are going and what they're doing")
	language.Add("tool.ngl_track.left", "Track the NPC you aim at (again to stop)")
	language.Add("tool.ngl_track.right", "Stop tracking all")
end

local function use(self, trace, button)
	if CLIENT then return true end
	if not (NGL and NGL.Tools) then return false end
	return NGL.Tools.Track(self:GetOwner(), trace, button)
end

function TOOL:LeftClick(trace) return use(self, trace, "left") end
function TOOL:RightClick(trace) return use(self, trace, "right") end

if CLIENT then
	function TOOL.BuildCPanel(panel)
		panel:Help("Left click NGL NPCs to track them. Blue: the path ahead (yellow: jump down, orange: jump up, purple: climb). White: where it has been. Green ring: where it's heading. Pink ring: where a player sent it.")
		panel:CheckBox("Keep showing them with another tool or weapon out", "ngl_track_always")
	end
end
