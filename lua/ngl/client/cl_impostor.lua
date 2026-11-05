-- Far-away NPCs drawn as flat pictures ("impostors").
--
-- Drawing an NPC costs most of its time before a single pixel: the engine
-- works out the pose of every bone (the animation), skins the mesh with
-- them, and does it again for the weapon. A far NPC is 10 to 25 pixels
-- tall, so all of that buys almost nothing. Past ngl_cl_impostor_range this
-- client draws such NPCs as a picture of the NPC instead: one textured
-- square turned to face you, all of them in one batch. No bones, no
-- skinning, no weapon model.
--
-- The pictures are made on this client, from the NPC's own model, the
-- first time they are needed ("baked"): for each model (with its skin,
-- bodygroups and weapon) and each animation it plays far away, 8 views
-- round it (front, front-left, left, ...) times 4 moments of the animation.
-- The picture shown is the view nearest to where you look at it from and
-- the moment nearest to where its animation is, so it still walks, runs
-- and turns. Pictures are kept in a few big textures (ngl_cl_impostor_atlases,
-- 16 MB of video memory each); when they are full, the pictures of what
-- nobody has needed for a few seconds make room.
--
-- An NPC whose picture isn't baked yet is drawn normally until it is
-- (ngl_cl_impostor_bake pictures a frame). Vehicles and NPCs with
-- ENT.NoImpostor = true are always drawn normally.
--
-- Only how this client draws changes, as with the other client settings.
-- ngl_cl_impostor_show 1 shows the first texture on screen, to see what was
-- baked.

NGL.Impostor = NGL.Impostor or {}
local I = NGL.Impostor

local cvOn = CreateClientConVar("ngl_cl_impostor", "1", true, false,
	"1 = NGL NPCs further than ngl_cl_impostor_range are drawn as flat pictures of themselves, made on the fly from their own model (much cheaper: no bones, no skinning). 0 = always the real model.", 0, 1)
local cvRange = CreateClientConVar("ngl_cl_impostor_range", "3000", true, false,
	"NGL NPCs further than this are drawn as flat pictures (ngl_cl_impostor). Lower = more FPS, but you see the pictures closer up.", 0, 50000)
local cvAtlases = CreateClientConVar("ngl_cl_impostor_atlases", "2", true, false,
	"Textures for NPC pictures, 16 MB of video memory each, 50 animations of one model each. 0 = no pictures.", 0, 8)
local cvBake = CreateClientConVar("ngl_cl_impostor_bake", "24", true, false,
	"Most NPC pictures made a frame. NPCs whose picture isn't made yet are drawn normally.", 1, 512)
local cvLight = CreateClientConVar("ngl_cl_impostor_light", "2", true, false,
	"How strongly the map's light at each NPC darkens or tints its picture. Higher = brighter pictures.", 0, 20)
local cvShow = CreateClientConVar("ngl_cl_impostor_show", "0", false, false,
	"Shows NPC picture texture N on screen (1 = the first). 0 = off.", 0, 8)

local ATLAS = 2048                 -- texture size, pixels
local TILE = 48                    -- one picture, pixels (a far NPC is 10 to 25 tall)
local DIRS, FRAMES = 8, 4          -- views round the model, moments of the animation
local BLOCK_W, BLOCK_H = DIRS * TILE, FRAMES * TILE -- one animation of one model: 384 x 192
local BCOLS, BROWS = math.floor(ATLAS / BLOCK_W), math.floor(ATLAS / BLOCK_H)
local PER_ATLAS = BCOLS * BROWS    -- 5 x 10 = 50 animations a texture
local FOV = 8                      -- narrow lens from far away: nearly flat, like the picture
local ELEV = 6                     -- degrees the baking camera looks down
local LEAVE = 0.92                 -- back to the real model this much closer than the range
local EVICT_AFTER = 5              -- seconds unused before an animation's pictures may be replaced
local KEY_REFRESH = 2              -- seconds between checks of an NPC's skin and bodygroups
local LIGHT_REFRESH = 1            -- seconds between samples of the light at an NPC
local RIG_KEEP = 60                -- seconds a baking model is kept after its last use
local MAX_QUADS = 2000             -- pictures per draw call

I.TILE, I.DIRS, I.FRAMES, I.PER_ATLAS = TILE, DIRS, FRAMES, PER_ATLAS

local atlases = {}  -- [i] = { rt, mat, dbg }
local blocks = {}   -- texture slots, one animation of one model each
local byId = {}     -- "<key>#<sequence>" -> block
local rigs = {}     -- key -> hidden models used for baking
local queue, qHead, queued = {}, 1, {}
local quads = {}    -- [atlas] = flat list of numbers for this frame's pictures
local nQuads = {}

local floor, sqrt, deg, atan2, min, max = math.floor, math.sqrt, math.deg, math.atan2, math.min, math.max

----------------------------------------------------------------------------
-- Picking a picture
----------------------------------------------------------------------------

-- Which of the 8 views: `rel` is the direction you look at the NPC from,
-- in degrees, relative to the way it faces (0 = from straight in front).
local function dirIndex(rel)
	return floor(((rel % 360) + 180 / DIRS) / (360 / DIRS)) % DIRS
end
-- Which of the 4 moments of its animation.
local function frameIndex(cycle)
	return floor((cycle % 1) * FRAMES) % FRAMES
end
I._dirIndex, I._frameIndex = dirIndex, frameIndex

-- Where texture slot k (1-based) is: texture, x, y.
local function slotPlace(k)
	local a = floor((k - 1) / PER_ATLAS) + 1
	local j = (k - 1) % PER_ATLAS
	return a, (j % BCOLS) * BLOCK_W, floor(j / BCOLS) * BLOCK_H
end
I._slotPlace = slotPlace

local function atlas(i)
	local a = atlases[i]
	if a then return a end
	local rt = GetRenderTargetEx("ngl_impostor_" .. i, ATLAS, ATLAS, RT_SIZE_NO_CHANGE,
		MATERIAL_RT_DEPTH_SEPARATE, bit.bor(4, 8, 256), 0, IMAGE_FORMAT_RGBA8888) -- clamp, no mipmaps
	local mat = CreateMaterial("ngl_impostor_mat_" .. i, "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$alphatest"] = "1",
		["$alphatestreference"] = "0.5",
		["$vertexcolor"] = "1",
		["$nocull"] = "1",
	})
	mat:SetTexture("$basetexture", rt)
	local dbg = CreateMaterial("ngl_impostor_dbg_" .. i, "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$translucent"] = "1",
		["$vertexcolor"] = "1",
		["$vertexalpha"] = "1",
	})
	dbg:SetTexture("$basetexture", rt)
	-- Only ever made while baking, inside the frame's rendering: start empty.
	render.PushRenderTarget(rt)
	render.Clear(0, 0, 0, 0, true, true)
	render.PopRenderTarget()
	a = { rt = rt, mat = mat, dbg = dbg }
	atlases[i] = a
	return a
end

-- The texture slot for one animation of one model: the one it already has,
-- a free one, or the one nobody has used for longest (if that was more
-- than EVICT_AFTER seconds ago). nil when everything is in use.
local function getBlock(key, seq, now)
	local id = key .. "#" .. seq
	local b = byId[id]
	if b then
		b.used = now
		return b
	end
	local cap = cvAtlases:GetInt() * PER_ATLAS
	if #blocks < cap then
		local k = #blocks + 1
		local a, x, y = slotPlace(k)
		b = { atlas = a, x = x, y = y }
		blocks[k] = b
	else
		local oldest
		for _, c in ipairs(blocks) do
			if c.used < now - EVICT_AFTER and (not oldest or c.used < oldest.used) then oldest = c end
		end
		if not oldest then return nil end
		byId[oldest.id] = nil
		b = oldest
	end
	b.id, b.key, b.seq, b.used, b.ready = id, key, seq, now, {}
	byId[id] = b
	return b
end
I._getBlock = getBlock

----------------------------------------------------------------------------
-- Baking
----------------------------------------------------------------------------

-- What makes two NPCs look the same: model, skin, bodygroups, weapon.
local function keyOf(npc, now)
	if npc.NGLImpKey and now < (npc.NGLImpKeyAt or 0) then return npc.NGLImpKey end
	local parts = { npc:GetModel() or "", npc:GetSkin() or 0, npc.WeaponModel or "" }
	local nb = npc:GetNumBodyGroups() or 0
	if nb > 1 then
		local bg = {}
		for i = 0, nb - 1 do bg[#bg + 1] = npc:GetBodygroup(i) end
		parts[#parts + 1] = table.concat(bg, ",")
	end
	npc.NGLImpKey = table.concat(parts, "|")
	npc.NGLImpKeyAt = now + KEY_REFRESH * math.Rand(0.8, 1.2)
	return npc.NGLImpKey
end

local POSES = { move_yaw = 0, move_x = 1, move_y = 0, aim_yaw = 0, aim_pitch = 0 }

-- A hidden copy of the NPC (and its weapon) to take pictures of.
local function getRig(key, npc, now)
	local r = rigs[key]
	if r and IsValid(r.ent) then
		r.used = now
		return r
	end
	local ent = ClientsideModel(npc:GetModel(), RENDERGROUP_OPAQUE)
	if not IsValid(ent) then return nil end
	ent:SetNoDraw(true)
	ent:SetPos(vector_origin)
	ent:SetAngles(angle_zero)
	ent:SetSkin(npc:GetSkin() or 0)
	for i = 1, (npc:GetNumBodyGroups() or 1) - 1 do ent:SetBodygroup(i, npc:GetBodygroup(i)) end
	local poses = {}
	for name, v in pairs(POSES) do
		if ent:LookupPoseParameter(name) >= 0 then poses[name] = v end
	end
	local wep
	if npc.WeaponModel then
		wep = ClientsideModel(npc.WeaponModel, RENDERGROUP_OPAQUE)
		if IsValid(wep) then
			wep:SetNoDraw(true)
			wep:SetParent(ent)
			wep:AddEffects(EF_BONEMERGE)
		else
			wep = nil
		end
	end
	-- Framing: the NPC's own box (its hull), with room for a gun held out
	-- and arms swinging.
	local mins, maxs = npc:OBBMins(), npc:OBBMaxs()
	local h = maxs.z - mins.z
	local w = max(maxs.x - mins.x, maxs.y - mins.y)
	r = {
		ent = ent, wep = wep, poses = poses, used = now,
		cz = (mins.z + maxs.z) * 0.5,
		half = max(h * 0.5, w) * 1.3,
	}
	rigs[key] = r
	return r
end

local function removeRig(r)
	if IsValid(r.wep) then r.wep:Remove() end
	if IsValid(r.ent) then r.ent:Remove() end
end

local function request(b, d, f, t)
	local qk = b.id .. ":" .. t
	if queued[qk] then return end
	queued[qk] = true
	queue[#queue + 1] = { b = b, id = b.id, d = d, f = f, t = t, qk = qk }
end

-- Paints the silhouette's alpha: the model again, white, alpha only.
local maskMat = CreateMaterial("ngl_impostor_mask", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$model"] = "1",
})

local function bake(job)
	local b = job.b
	if b.id ~= job.id then return end -- the slot was given to another animation
	local r = rigs[b.key]
	if not r or not IsValid(r.ent) then return end
	local a = atlas(b.atlas)
	local ent, wep = r.ent, r.wep

	ent:SetSequence(b.seq)
	ent:SetCycle((job.f + 0.5) / FRAMES)
	for name, v in pairs(r.poses) do ent:SetPoseParameter(name, v) end
	ent:InvalidateBoneCache()
	if wep then wep:InvalidateBoneCache() end

	local center = Vector(0, 0, r.cz)
	local half = r.half
	local dist = half / math.tan(math.rad(FOV * 0.5))
	local camPos = center + Angle(-ELEV, job.d * (360 / DIRS), 0):Forward() * dist
	local camAng = (center - camPos):Angle()
	local x, y = b.x + job.d * TILE, b.y + job.f * TILE

	render.PushRenderTarget(a.rt)
	cam.Start3D(camPos, camAng, FOV, x, y, TILE, TILE, dist - half * 3, dist + half * 3)
		render.Clear(0, 0, 0, 0, true, true)
		render.SetWriteDepthToDestAlpha(false)
		render.SuppressEngineLighting(true)
		render.SetLightingOrigin(center)
		render.ResetModelLighting(0.55, 0.55, 0.55)
		render.SetModelLighting(BOX_TOP, 1, 1, 1)
		render.SetColorModulation(1, 1, 1)
		render.SetBlend(1)
		-- Colour, without touching alpha (model textures keep other things
		-- in their alpha, which would punch holes in the picture).
		render.OverrideAlphaWriteEnable(true, false)
		ent:DrawModel()
		if wep then wep:DrawModel() end
		-- Then alpha only: 1 wherever the model is.
		render.OverrideAlphaWriteEnable(true, true)
		render.OverrideColorWriteEnable(true, false)
		render.ClearDepth()
		render.MaterialOverride(maskMat)
		ent:DrawModel()
		if wep then wep:DrawModel() end
		render.MaterialOverride(nil)
		render.OverrideColorWriteEnable(false, true)
		render.OverrideAlphaWriteEnable(false, true)
		render.SuppressEngineLighting(false)
		render.SetWriteDepthToDestAlpha(true)
	cam.End3D()
	render.PopRenderTarget()

	b.ready[job.t] = true
end

local nextClean = 0
hook.Add("PreRender", "NGL.Impostor.Bake", function()
	for i in pairs(nQuads) do nQuads[i] = 0 end
	local now = RealTime()

	if now > nextClean then
		nextClean = now + 10
		for key, r in pairs(rigs) do
			if now - r.used > RIG_KEEP then
				removeRig(r)
				rigs[key] = nil
			end
		end
	end

	if qHead > #queue then return end
	local fog = render.GetFogMode()
	render.FogMode(MATERIAL_FOG_NONE)
	local left = cvBake:GetInt()
	while left > 0 and qHead <= #queue do
		local job = queue[qHead]
		queue[qHead] = nil
		qHead = qHead + 1
		queued[job.qk] = nil
		bake(job)
		left = left - 1
	end
	render.FogMode(fog)
	if qHead > #queue then queue, qHead = {}, 1 end
end)

----------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------

-- Called from the NPC's Draw (main view only, cl_init.lua) with its
-- distance squared. true = it's drawn as a picture this frame, so the
-- caller draws nothing.
function I.Draw(npc, d)
	if not cvOn:GetBool() or npc.IsVehicleNPC or npc.NoImpostor then
		npc.NGLImp = false
		return false
	end
	local range = cvRange:GetFloat()
	if range <= 0 or cvAtlases:GetInt() <= 0 then
		npc.NGLImp = false
		return false
	end
	local want
	if npc.NGLImp then want = d > (range * LEAVE) ^ 2 else want = d > range * range end
	npc.NGLImp = want
	if not want then return false end

	local now = RealTime()
	local key = keyOf(npc, now)
	local r = getRig(key, npc, now)
	if not r then return false end
	local seq = npc:GetSequence()
	local b = getBlock(key, seq, now)
	if not b then return false end

	local pos = npc:GetPos()
	local eye = EyePos()
	local dx, dy = pos.x - eye.x, pos.y - eye.y
	local rel = deg(atan2(-dy, -dx)) - npc:GetAngles().y
	local di = dirIndex(rel)
	local fi = frameIndex(npc:GetCycle())
	local t = di * FRAMES + fi + 1
	if not b.ready[t] then
		request(b, di, fi, t)
		return false
	end

	-- The map's light where it stands, now and then.
	if now >= (npc.NGLImpLightAt or 0) then
		npc.NGLImpLightAt = now + LIGHT_REFRESH * math.Rand(0.8, 1.2)
		local l = render.GetLightColor(pos + Vector(0, 0, r.cz)) * cvLight:GetFloat()
		npc.NGLImpR = floor(min(1, max(0.08, l.x)) * 255)
		npc.NGLImpG = floor(min(1, max(0.08, l.y)) * 255)
		npc.NGLImpB = floor(min(1, max(0.08, l.z)) * 255)
	end

	local l = sqrt(dx * dx + dy * dy)
	if l < 1 then return false end
	local q = quads[b.atlas]
	if not q then
		q = {}
		quads[b.atlas] = q
	end
	local n = (nQuads[b.atlas] or 0)
	local o = n * 11
	q[o + 1], q[o + 2], q[o + 3] = pos.x, pos.y, pos.z + r.cz
	q[o + 4], q[o + 5] = dy / l * r.half, -dx / l * r.half -- to the right of the view, half a picture
	q[o + 6] = r.half
	q[o + 7] = (b.x + di * TILE + 0.5) / ATLAS
	q[o + 8] = (b.y + fi * TILE + 0.5) / ATLAS
	q[o + 9], q[o + 10], q[o + 11] = npc.NGLImpR or 255, npc.NGLImpG or 255, npc.NGLImpB or 255
	nQuads[b.atlas] = n + 1
	return true
end

local vtx = Vector()
local UV = (TILE - 1) / ATLAS
local function corner(x, y, z, u, v, cr, cg, cb)
	vtx:SetUnpacked(x, y, z)
	mesh.Position(vtx)
	mesh.TexCoord(0, u, v)
	mesh.Color(cr, cg, cb, 255)
	mesh.AdvanceVertex()
end

-- All pictures of the frame, one batch per texture, in the opaque pass
-- (alpha-tested: they hide what's behind them and get the map's fog).
hook.Add("PostDrawOpaqueRenderables", "NGL.Impostor.Draw", function(depth, sky)
	if depth or sky then return end
	if NGL.InMainView and not NGL.InMainView() then return end
	for ai, n in pairs(nQuads) do
		if n > 0 and atlases[ai] then
			local q = quads[ai]
			render.SetMaterial(atlases[ai].mat)
			local i = 0
			while i < n do
				local batch = min(MAX_QUADS, n - i)
				mesh.Begin(MATERIAL_QUADS, batch)
				for k = i, i + batch - 1 do
					local o = k * 11
					local cx, cy, cz, rx, ry, h = q[o + 1], q[o + 2], q[o + 3], q[o + 4], q[o + 5], q[o + 6]
					local u0, v0 = q[o + 7], q[o + 8]
					local u1, v1 = u0 + UV, v0 + UV
					local cr, cg, cb = q[o + 9], q[o + 10], q[o + 11]
					corner(cx - rx, cy - ry, cz + h, u0, v0, cr, cg, cb)
					corner(cx + rx, cy + ry, cz + h, u1, v0, cr, cg, cb)
					corner(cx + rx, cy + ry, cz - h, u1, v1, cr, cg, cb)
					corner(cx - rx, cy - ry, cz - h, u0, v1, cr, cg, cb)
				end
				mesh.End()
				i = i + batch
			end
			nQuads[ai] = 0
		end
	end
end)

----------------------------------------------------------------------------
-- Starting over
----------------------------------------------------------------------------

-- Forgets every picture (they are baked again when needed; each picture
-- clears its own square). Textures lose what's in them when the screen mode
-- changes.
function I.Reset()
	blocks, byId = {}, {}
	queue, qHead, queued = {}, 1, {}
end

concommand.Add("ngl_cl_impostor_reset", function() I.Reset() end)
hook.Add("OnScreenSizeChanged", "NGL.Impostor.Reset", function() I.Reset() end)
cvars.AddChangeCallback("ngl_cl_impostor_atlases", function() I.Reset() end, "NGL.Impostor")

hook.Add("HUDPaint", "NGL.Impostor.Show", function()
	local i = cvShow:GetInt()
	if i <= 0 then return end
	local a = atlases[i]
	if not a then return end
	local s = math.min(ScrH() - 40, 768)
	surface.SetDrawColor(40, 40, 40, 200)
	surface.DrawRect(20, 20, s, s)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(a.dbg)
	surface.DrawTexturedRect(20, 20, s, s)
	local used = 0
	for _, b in ipairs(blocks) do if b.atlas == i and b.id then used = used + 1 end end
	draw.SimpleText(string.format("NGL impostors: texture %d, %d / %d animations", i, used, PER_ATLAS), "DermaDefault", 24, 24 + s, color_white)
end)
