-- Shared poses for mid-range crowds (experimental, ngl_cl_crowd 0 by default).
--
-- A full model costs most of its time before a pixel is drawn: the engine
-- works out the pose of every bone for that NPC's exact moment of its
-- animation, every frame. In a horde, dozens of NPCs play the same run at
-- nearly the same moment. Here NPCs between ngl_cl_crowd_range and the
-- picture range are drawn from poses worked out once and shared: each
-- animation of each model is posed at CROWD_FRAMES moments, once, and kept;
-- an NPC is drawn with the pose of the moment nearest its own, at its own
-- position, as the model's own meshes with those bones (IMesh:DrawSkinned).
-- 100 running zombies then cost 16 poses, made once, instead of 100 a
-- frame, and still look 3D (unlike the pictures further out).
--
-- What it gives up: the in-between moments (16 a loop), leg turns and aim
-- (poses are made facing straight ahead, legs straight, which is how
-- running NPCs move anyway), facial animation, decals, the map's detailed
-- lighting (it's lit like the pictures: the light where it stands), and
-- the weapon is drawn the same way from its own pose.
--
-- Needs IMesh:DrawSkinned and a skinned Mesh() (GMod 2026.02 and later;
-- may only be on the dev branch). Without them, or if anything goes wrong
-- while building or drawing, it turns itself off and says why in the
-- console, and NPCs are drawn normally. A model whose meshes can't be read
-- is drawn normally too.

NGL.Crowd = NGL.Crowd or {}
local C = NGL.Crowd

local cvOn = CreateClientConVar("ngl_cl_crowd", "0", true, false,
	"Experimental: 1 = NGL NPCs between ngl_cl_crowd_range and the picture range are drawn with poses shared by all NPCs at the same moment of the same animation (much less bone work in big crowds, a little stiffer). 0 = off.", 0, 1)
local cvRange = CreateClientConVar("ngl_cl_crowd_range", "1000", true, false,
	"With ngl_cl_crowd 1, NGL NPCs further than this (and nearer than the picture range) are drawn with shared poses.", 0, 50000)
local cvLod = CreateClientConVar("ngl_cl_crowd_lod", "1", true, false,
	"Model detail level the shared-pose NPCs are built from (0 = full, higher = fewer polygons, if the model has them).", 0, 7)
local cvLight = CreateClientConVar("ngl_cl_crowd_light", "1.5", true, false,
	"How strongly the map's light at each shared-pose NPC lights it.", 0, 20)

local cvBase = CreateClientConVar("ngl_cl_crowd_bone_base", "1", true, false,
	"Shared poses: how vertices name their bones. 1 = as in the wiki's DrawSkinned example (bone n is the table's entry n). 0 = counted from 0. Only for testing; takes effect after ngl_cl_crowd_reset.", 0, 1)

local CROWD_FRAMES = 16  -- poses per animation
local MAX_BONES = 51     -- matrices one DrawSkinned call takes (52, one kept spare)
local MAX_POSES = 6000   -- poses kept before they're all made again
local LIGHT_REFRESH = 1  -- s between samples of the light at an NPC
local POSES = { move_yaw = 0, move_x = 1, move_y = 0, aim_yaw = 0, aim_pitch = 0 }

local floor, min, max = math.floor, math.min, math.max

C.Broken = C.Broken or nil
local function say(msg)
	MsgC(Color(120, 200, 255), "[NGL] ", color_white, msg, "\n")
end
local function supported()
	local IM = FindMetaTable("IMesh")
	return IM ~= nil and IM.DrawSkinned ~= nil and mesh.BoneData ~= nil
end

----------------------------------------------------------------------------
-- Models: the meshes, split so each piece uses at most MAX_BONES bones
----------------------------------------------------------------------------

local models = {} -- key -> { parts = { {mat, imesh, bones = {boneId...}, slots = {}} }, bind, rig } or false
local building = {} -- keys waiting to be built (one a frame)

-- What the meshes depend on: model, bodygroups, skin (the weapon is its own key).
local function bodyMask(ent)
	local nb = ent:GetNumBodyGroups() or 0
	if nb <= 1 then return 0, "" end
	local t = {}
	for i = 0, nb - 1 do t[#t + 1] = string.format("%d", min(9, ent:GetBodygroup(i) or 0)) end
	local s = table.concat(t)
	return s, s
end

-- Two strongest bone weights of a vertex, summing to 1.
local function topWeights(w)
	local b1, w1, b2, w2 = 0, 0, 0, 0
	if w then
		for _, bw in ipairs(w) do
			local b, x = bw.bone, bw.weight or 0
			if b then
				if x > w1 then b2, w2 = b1, w1; b1, w1 = b, x
				elseif x > w2 then b2, w2 = b, x end
			end
		end
	end
	local s = w1 + w2
	if s <= 0 then return b1, 1, b1, 0 end
	return b1, w1 / s, b2, w2 / s
end

-- One model's meshes as skinned IMeshes, cut into pieces of at most
-- MAX_BONES bones (by whole triangles).
local function buildParts(model, mask, skin)
	local lod = cvLod:GetInt()
	-- Each vertex names its bones by their place in the matrices table given
	-- to DrawSkinned. The wiki's example names them as the table's keys
	-- (1, 2, ...); naming them from 0 put every vertex on its neighbour's
	-- bone: heads floating, guns on the ground (0.31.1).
	local off = cvBase:GetInt() == 1 and 0 or -1
	local meshes, bind = util.GetModelMeshes(model, lod, mask, skin)
	if (not meshes or #meshes == 0) and lod > 0 then meshes, bind = util.GetModelMeshes(model, 0, mask, skin) end
	if not meshes or #meshes == 0 or not bind then return nil end
	local parts = {}
	for _, md in ipairs(meshes) do
		local tris = md.triangles
		if tris and #tris >= 3 then
			local mat = Material(md.material)
			-- Greedy cut: add triangles while their bones fit.
			local cur, curBones, curIdx, curTris = nil, nil, nil, nil
			local function flush()
				if cur and #curTris > 0 then cur.tris = curTris parts[#parts + 1] = cur end
				cur, curBones, curIdx, curTris = { mat = mat, bones = {} }, {}, {}, {}
				cur.bones = curBones
			end
			flush()
			for i = 1, #tris - 2, 3 do
				local need = 0
				local tri = { tris[i], tris[i + 1], tris[i + 2] }
				local wsets = {}
				for k = 1, 3 do
					local b1, w1, b2, w2 = topWeights(tri[k].weights)
					wsets[k] = { b1, w1, b2, w2 }
					if not curIdx[b1] then need = need + 1 end
					if w2 > 0 and b2 ~= b1 and not curIdx[b2] then need = need + 1 end
				end
				if #curBones + need > MAX_BONES then flush() end
				for k = 1, 3 do
					local ws = wsets[k]
					for _, b in ipairs({ ws[1], ws[3] }) do
						if not curIdx[b] then
							curBones[#curBones + 1] = b
							curIdx[b] = #curBones
						end
					end
					curTris[#curTris + 1] = { v = tri[k], s1 = curIdx[ws[1]] + off, w1 = ws[2], s2 = curIdx[ws[3]] + off, w2 = ws[4] }
				end
			end
			flush()
		end
	end
	-- Into meshes.
	for _, p in ipairs(parts) do
		local im = Mesh(p.mat, 2)
		local n = floor(#p.tris / 3)
		mesh.Begin(im, MATERIAL_TRIANGLES, n)
		local ok, err = pcall(function()
			for _, t in ipairs(p.tris) do
				local v = t.v
				mesh.Position(v.pos)
				if v.normal then mesh.Normal(v.normal) end
				mesh.TexCoord(0, v.u or 0, v.v or 0)
				if v.userdata then mesh.UserData(v.userdata[1] or 0, v.userdata[2] or 0, v.userdata[3] or 0, v.userdata[4] or 1) end
				mesh.BoneData(0, t.s1, t.w1)
				mesh.BoneData(1, t.s2, t.w2)
				mesh.Color(255, 255, 255, 255)
				mesh.AdvanceVertex()
			end
		end)
		mesh.End()
		if not ok then error(err) end
		p.imesh = im
		p.tris = nil
		p.slots = { [0] = Matrix() } -- reused table of matrices for one draw
	end
	if #parts == 0 then return nil end
	return parts, bind
end

-- A hidden copy at the origin to pose (with its weapon bonemerged).
local function makeRig(model, skin, ent)
	local r = ClientsideModel(model, RENDERGROUP_OPAQUE)
	if not IsValid(r) then return nil end
	r:SetNoDraw(true)
	r:SetPos(vector_origin)
	r:SetAngles(angle_zero)
	r:SetSkin(skin)
	if ent then
		for i = 1, (ent:GetNumBodyGroups() or 1) - 1 do r:SetBodygroup(i, ent:GetBodygroup(i)) end
	end
	return r
end

local function getModel(npc)
	local key = npc.NGLCrowdKey
	if not key then
		local mask, ms = bodyMask(npc)
		key = (npc:GetModel() or "") .. "|" .. (npc:GetSkin() or 0) .. "|" .. ms .. "|" .. (npc.WeaponModel or "")
		npc.NGLCrowdKey, npc.NGLCrowdMask = key, mask
	end
	local m = models[key]
	if m ~= nil then return m end
	-- Built one a frame (reading a model's meshes takes a while).
	if not building[key] then
		building[key] = npc
		building[#building + 1] = key
	end
	return nil
end

local function buildOne()
	local key = table.remove(building, 1)
	if not key then return end
	local npc = building[key]
	building[key] = nil
	if models[key] ~= nil or not IsValid(npc) then return end
	local model, skin = npc:GetModel(), npc:GetSkin() or 0
	local parts, bind = buildParts(model, npc.NGLCrowdMask or 0, skin)
	if not parts then
		models[key] = false
		return
	end
	local rig = makeRig(model, skin, npc)
	if not rig then
		models[key] = false
		return
	end
	local poses = {}
	for name, v in pairs(POSES) do
		if rig:LookupPoseParameter(name) >= 0 then poses[name] = v end
	end
	local m = { parts = parts, bind = bind, rig = rig, poses = poses, posed = {} }
	-- The weapon: its own meshes and pose, bonemerged to the rig.
	if npc.WeaponModel then
		local wparts, wbind = buildParts(npc.WeaponModel, 0, 0)
		local wrig = wparts and makeRig(npc.WeaponModel, 0)
		if wrig then
			wrig:SetParent(rig)
			wrig:AddEffects(EF_BONEMERGE)
			m.wep = { parts = wparts, bind = wbind, rig = wrig }
		end
	end
	models[key] = m
end

----------------------------------------------------------------------------
-- Poses: skinning matrices (bone pose times the inverse bind pose) for one
-- moment of one animation, made once
----------------------------------------------------------------------------

local nPoses = 0
local function skinMatrices(rig, bind)
	local out = {}
	for b = 0, #bind do
		local bm = rig:GetBoneMatrix(b)
		local bp = bind[b]
		if bm and bp and bp.matrix then
			out[b] = bm * bp.matrix
		else
			out[b] = Matrix()
		end
	end
	return out
end

local function getPose(m, seq, f)
	local id = seq * CROWD_FRAMES + f
	local p = m.posed[id]
	if p then return p end
	if nPoses >= MAX_POSES then
		for _, mm in pairs(models) do if mm then mm.posed = {} end end
		nPoses = 0
	end
	local rig = m.rig
	rig:SetSequence(seq)
	rig:SetCycle((f + 0.5) / CROWD_FRAMES)
	for name, v in pairs(m.poses) do rig:SetPoseParameter(name, v) end
	rig:InvalidateBoneCache()
	rig:SetupBones()
	p = { body = skinMatrices(rig, m.bind) }
	if m.wep then
		local w = m.wep.rig
		w:InvalidateBoneCache()
		w:SetupBones()
		p.wep = skinMatrices(w, m.wep.bind)
	end
	m.posed[id] = p
	nPoses = nPoses + 1
	return p
end

----------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------

local world = Matrix()
local lightAt = Vector()
local angBuf = Angle()

local function drawParts(parts, skin)
	for _, p in ipairs(parts) do
		local slots, bones = p.slots, p.bones
		for k = 1, #bones do slots[k] = skin[bones[k]] end
		render.SetMaterial(p.mat)
		p.imesh:DrawSkinned(slots, true)
	end
end

-- From the NPC's Draw (main view, cl_init.lua), after the picture check:
-- true = drawn here with a shared pose, the caller draws nothing.
function C.Draw(npc, d, pos)
	if not cvOn:GetBool() or C.Broken or npc.IsVehicleNPC or npc.NoImpostor then return false end
	local r = cvRange:GetFloat() * (NGL.ClScale or 1)
	if d < r * r then return false end
	if not supported() then
		C.Broken = "this GMod has no IMesh:DrawSkinned (needs a 2026.02 or newer build, maybe the dev branch)"
		say("shared poses turned off: " .. C.Broken .. ".")
		return false
	end
	local m = getModel(npc)
	if not m then return false end
	local seq = npc:GetSequence()
	local f = floor((npc:GetCycle() % 1) * CROWD_FRAMES) % CROWD_FRAMES
	local ok, err = pcall(function()
		local p = getPose(m, seq, f)
		local now = RealTime()
		if now >= (npc.NGLCrowdLightAt or 0) then
			npc.NGLCrowdLightAt = now + LIGHT_REFRESH * math.Rand(0.8, 1.2)
			lightAt:SetUnpacked(pos.x, pos.y, pos.z + 36)
			local l = render.GetLightColor(lightAt)
			local k = cvLight:GetFloat()
			npc.NGLCrowdR, npc.NGLCrowdG, npc.NGLCrowdB = min(1, l.x * k), min(1, l.y * k), min(1, l.z * k)
		end
		local lr, lg, lb = npc.NGLCrowdR or 0.5, npc.NGLCrowdG or 0.5, npc.NGLCrowdB or 0.5
		local a = npc:GetAngles()
		angBuf:SetUnpacked(0, a.y, 0)
		world:Identity()
		world:SetTranslation(pos)
		world:SetAngles(angBuf)
		render.SuppressEngineLighting(true)
		render.SetLightingOrigin(pos)
		render.SetLocalModelLights()
		render.ResetModelLighting(lr * 0.6, lg * 0.6, lb * 0.6)
		render.SetModelLighting(BOX_TOP, lr, lg, lb)
		cam.PushModelMatrix(world)
		drawParts(m.parts, p.body)
		if m.wep and p.wep then drawParts(m.wep.parts, p.wep) end
		cam.PopModelMatrix()
		render.SuppressEngineLighting(false)
	end)
	if not ok then
		render.SuppressEngineLighting(false)
		pcall(cam.PopModelMatrix)
		C.Broken = "Lua error while drawing: " .. tostring(err)
		say("shared poses turned off: " .. C.Broken)
		return false
	end
	return true
end

hook.Add("Think", "NGL.Crowd.Build", function()
	if #building == 0 or C.Broken or not cvOn:GetBool() then return end
	local ok, err = pcall(buildOne)
	if not ok then
		C.Broken = "Lua error while reading a model: " .. tostring(err)
		say("shared poses turned off: " .. C.Broken)
	end
end)

-- ngl_cl_crowd_reset: build every model again and try again after an error.
concommand.Add("ngl_cl_crowd_reset", function()
	for _, m in pairs(models) do
		if m then
			if IsValid(m.rig) then m.rig:Remove() end
			if m.wep and IsValid(m.wep.rig) then m.wep.rig:Remove() end
		end
	end
	models, building, nPoses = {}, {}, 0
	C.Broken = nil
	for _, e in ipairs(ents.GetAll()) do if e.IsNGLNPC then e.NGLCrowdKey = nil end end
	say("shared poses reset.")
end)
