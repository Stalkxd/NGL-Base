-- Client side of ngl_debug_parts (sv_parts.lua): times this client's
-- frames, and the server frame time net_graph shows, in each window the
-- server marks, and sends the averages back when it's done.

local MSG_START, MSG_END, MSG_DONE = 1, 2, 3
local windows = {}  -- [i] = { frame = sum, sv = sum, n = count }
local cur, last

hook.Add("Think", "NGL.PartsTest", function()
	if not cur then return end
	local now = SysTime()
	-- Unfocused, the game sleeps between frames: those don't count.
	if last and system.HasFocus() then
		cur.frame = cur.frame + (now - last) * 1000
		local sv = engine.ServerFrameTime and engine.ServerFrameTime()
		cur.sv = cur.sv + (sv and sv * 1000 or 0)
		cur.n = cur.n + 1
	end
	last = now
end)

net.Receive("ngl_parts", function()
	local kind, i = net.ReadUInt(2), net.ReadUInt(8)
	if kind == MSG_START then
		-- Parts switched off here, on the client (cl_init.lua reads it).
		local part, class = net.ReadString(), net.ReadString()
		NGL.ClOff = (part == "draw" or part == "lowlod" or part == "clanim") and { [part] = true, class = class ~= "" and class or nil } or nil
		if i == 1 then windows = {} end
		cur = { frame = 0, sv = 0, n = 0 }
		windows[i] = cur
		last = nil
	elseif kind == MSG_END then
		cur, last = nil, nil
		NGL.ClOff = nil
	elseif kind == MSG_DONE then
		cur, last = nil, nil
		NGL.ClOff = nil
		net.Start("ngl_parts")
		net.WriteUInt(i, 8)
		for k = 1, i do
			local w = windows[k] or { frame = 0, sv = 0, n = 0 }
			local n = math.min(w.n, 65535)
			net.WriteFloat(w.n > 0 and w.frame / w.n or 0)
			net.WriteFloat(w.n > 0 and w.sv / w.n or 0)
			net.WriteUInt(n, 16)
		end
		net.SendToServer()
	end
end)
