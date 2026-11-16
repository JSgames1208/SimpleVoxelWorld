-- Connected Discord-GitHub
-- Roblox username: @JasperFrietnr3
-- Discord (id): jasper6501

--!strict

const AssetService = game:GetService("AssetService")
--[[
Small version of my optimized fast voxel engine that fits in one, big file
Note that this specific version is made for submission, but it is made by putting a couple of small systems together from my bigger ongoing project
It uses EditableMeshes despite the usage limits being annoying, at a limit of 7 or 8 per client
This version skips that concern by baking the meshes instead of permanently assigning them to a chunk
Performance might be a tiny bit slower for extensive block breaking and placing
But as tested in my bigger version of this project, that is not a big problem, even allowing flowing water to work relatively smoothly

Note: These algorithms are all quite common knowledge for making voxel engines and they weren't invented by me.
Baking the meshes and reusing the editablemeshes as a way to bypass the client limit is a method I've never seen on the platform though.

Thanks for reading through this.
]]

const CHUNK_SIZE = 16 -- most fixed variables will be with "const", it's a relatively new feature, but makes it impossible to accidentally reassign it
const MAX_VERTICES = 60000 -- Roblox' vertex limit on editablemeshes
local WATER_DROP = 0.12 -- fraction of a block the water level sits below the surface
local WATER_TRANSPARENCY = 0.35

const Blocks = {
	Air = 0,
	Grass = 1,
	Dirt = 2,
	Stone = 3,
	Sand = 4,
	Water = 5,
	Wood = 6,
	Leaves = 7,
	Snow = 8,
}

type BlockInfo = {
	top: Color3, -- first 3 lines are the colors
	side: Color3,
	bottom: Color3,
	opaque: boolean, -- if you can see through or not
	water: boolean,
}

-- load all blocks when the game starts, which codes the colors
-- this const info at the top of the script makes access to it easy at any point in the code
local function loadAllBlocks(): { [number]: BlockInfo }
	local blocks: { [number]: BlockInfo } = {}
	local function define(id: number, top: Color3, side: Color3?, bottom: Color3?, kind: string?) -- kind is for special blocks, only water in this case
		blocks[id] = {
			top = top,
			side = side or top,
			bottom = bottom or side or top,
			opaque = kind == nil, -- everything except water is opaque
			water = kind == "water",
		}
	end
	-- defining every block with colors, multiple times if it's not a uniform color all the way around
	define(Blocks.Grass, Color3.fromRGB(106, 170, 72), Color3.fromRGB(128, 104, 70), Color3.fromRGB(121, 85, 58))
	define(Blocks.Dirt, Color3.fromRGB(121, 85, 58))
	define(Blocks.Stone, Color3.fromRGB(128, 128, 132))
	define(Blocks.Sand, Color3.fromRGB(220, 207, 150))
	define(Blocks.Water, Color3.fromRGB(52, 110, 200), nil, nil, "water") -- special case where water has a uniform color all the way around, but has to set the kind to "water"
	define(Blocks.Wood, Color3.fromRGB(160, 125, 80), Color3.fromRGB(105, 78, 50))
	define(Blocks.Leaves, Color3.fromRGB(62, 128, 52))
	define(Blocks.Snow, Color3.fromRGB(240, 244, 250), Color3.fromRGB(200, 205, 212), Color3.fromRGB(121, 85, 58))

	return blocks
end

const INFO = loadAllBlocks()

type Face = {
	normal: Vector3,
	origin: Vector3,
	u: Vector3,
	v: Vector3,
	offset: Vector3,
	shade: number,
	side: string,
}
const FACES: { Face } = { -- automatic stylua linter making it impossible to write this shorter ):
	{
		normal = Vector3.xAxis,
		origin = Vector3.new(1, 0, 1),
		u = -Vector3.zAxis,
		v = Vector3.yAxis,
		offset = Vector3.xAxis,
		shade = 0.8,
		side = "side",
	},
	{
		normal = -Vector3.xAxis,
		origin = Vector3.zero,
		u = Vector3.zAxis,
		v = Vector3.yAxis,
		offset = -Vector3.xAxis,
		shade = 0.8,
		side = "side",
	},
	{
		normal = Vector3.yAxis,
		origin = Vector3.new(0, 1, 1),
		u = Vector3.xAxis,
		v = -Vector3.zAxis,
		offset = Vector3.yAxis,
		shade = 1,
		side = "top",
	},
	{
		normal = -Vector3.yAxis,
		origin = Vector3.zero,
		u = Vector3.xAxis,
		v = Vector3.zAxis,
		offset = -Vector3.yAxis,
		shade = 0.55,
		side = "bottom",
	},
	{
		normal = Vector3.zAxis,
		origin = Vector3.new(0, 0, 1),
		u = Vector3.xAxis,
		v = Vector3.yAxis,
		offset = Vector3.zAxis,
		shade = 0.68,
		side = "side",
	},
	{
		normal = -Vector3.zAxis,
		origin = Vector3.new(1, 0, 0),
		u = -Vector3.xAxis,
		v = Vector3.yAxis,
		offset = -Vector3.zAxis,
		shade = 0.68,
		side = "side",
	},
}

const CORNERS = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
const TRIANGLES = { { 1, 2, 3 }, { 1, 3, 4 } }
local JITTER_LEVELS = 4

export type Options = { -- basic settings to generate the world
	seed: number?, -- default random
	sizeInChunks: number?, -- world size is sizeInChunks x sizeInChunks, default 8, so 128x128 blocks
	height: number?, -- blocks, default 64
	seaLevel: number?, -- default 40% of height
	blockSize: number?, -- in studs, default 3
	origin: Vector3?, -- where to place world relative to roblox coordinates
	trees: boolean?, -- default tree
	parent: Instance?, -- where to put the folders, default workspace
}

local VoxelWorld = {}
VoxelWorld.__index = VoxelWorld
VoxelWorld.Blocks = Blocks

type Fields = {
	seed: number,
	size: number,
	height: number,
	seaLevel: number,
	blockSize: number,
	origin: Vector3,
	trees: boolean,
	noiseOffset: number,
	blocks: buffer,
	generated: boolean,
	folder: Folder,
	parts: { [string]: MeshPart },
}
export type VoxelWorld = setmetatable<Fields, typeof(VoxelWorld)> -- crazy way of doing it, new type solver stuff

function VoxelWorld.new(options: Options?): VoxelWorld
	local given: Options = options or {}
	local size = (given.sizeInChunks or 8) * CHUNK_SIZE
	local height = given.height or 64
	local blockSize = given.blockSize or 3
	local seed = given.seed or math.random(1, 2 ^ 30) -- generate a potentially very big number, so practically every random seed you generate is unique
	local folder = Instance.new("Folder")
	folder.Parent = given.parent or workspace
	return setmetatable({
		seed = seed,
		size = size,
		height = height,
		seaLevel = given.seaLevel or math.floor(height * 0.4),
		blockSize = blockSize,
		origin = given.origin or Vector3.new(-size / 2, 0, -size / 2) * blockSize,
		trees = given.trees ~= false,
		noiseOffset = Random.new(seed):NextNumber(-5000, 5000) + 0.37, -- not an integer, otherwise it just returns 0 for some reason
		blocks = buffer.create(size * size * height), -- buffer for optimization, it stores data in a more compact way than normal tables, but is generally harder to use
		generated = false,
		folder = folder,
		parts = {},
	}, VoxelWorld)
end

-- BLOCKS

function VoxelWorld.inBounds(self: VoxelWorld, x: number, y: number, z: number): boolean
	return x >= 0 and x < self.size and z >= 0 and z < self.size and y >= 0 and y < self.height
end

-- the whole world is one flat buffer, 1 byte per block, so the index is (y * size + z) * size + x
-- much faster than a 3d table, and my bigger version does the same
function VoxelWorld.getBlock(self: VoxelWorld, x: number, y: number, z: number): number
	x, y, z = math.floor(x), math.floor(y), math.floor(z) -- floors so you can pass in world positions directly
	if not self:inBounds(x, y, z) then
		return Blocks.Air -- outside the world is just air, so the edges of the world show their faces
	end
	return buffer.readu8(self.blocks, (y * self.size + z) * self.size + x)
end

-- raw write with no remeshing, only used while generating. Doesn't floor because we only call it with whole numbers
function VoxelWorld.writeBlock(self: VoxelWorld, x: number, y: number, z: number, block: number): ()
	if self:inBounds(x, y, z) then
		buffer.writeu8(self.blocks, (y * self.size + z) * self.size + x, block)
	end
end

-- the one you use for breaking/placing, writes the block and then redraws whatever chunks changed
function VoxelWorld.setBlock(self: VoxelWorld, x: number, y: number, z: number, block: number): ()
	x, y, z = math.floor(x), math.floor(y), math.floor(z)
	if not self:inBounds(x, y, z) or self:getBlock(x, y, z) == block then
		return -- nothing changed, so no reason to rebuild a mesh
	end
	self:writeBlock(x, y, z, block)
	if not self.generated then
		return -- world isn't drawn yet, generate() will draw everything anyway
	end
	local chunkX, chunkZ = x // CHUNK_SIZE, z // CHUNK_SIZE
	local localX, localZ = x % CHUNK_SIZE, z % CHUNK_SIZE
	local dirty = { { chunkX, chunkZ } } -- chunks that need a redraw
	-- a block on the edge of a chunk changes which faces the neighbouring chunk should show, so that one is dirty too
	-- -1 or 1 is the direction of the neighbour, 0 means not on that edge
	local sideX = if localX == 0 then -1 elseif localX == CHUNK_SIZE - 1 then 1 else 0
	local sideZ = if localZ == 0 then -1 elseif localZ == CHUNK_SIZE - 1 then 1 else 0
	if sideX ~= 0 then
		table.insert(dirty, { chunkX + sideX, chunkZ })
	end
	if sideZ ~= 0 then
		table.insert(dirty, { chunkX, chunkZ + sideZ })
	end
	for _, chunk in dirty do
		self:drawChunk(chunk[1], chunk[2])
	end
end

function VoxelWorld.surfaceHeight(self: VoxelWorld, x: number, z: number): number
	for y = self.height - 1, 0, -1 do
		local block = self:getBlock(x, y, z)
		if block ~= Blocks.Air and block ~= Blocks.Water then
			return y
		end
	end
	return -1
end

function VoxelWorld.blockToWorld(self: VoxelWorld, x: number, y: number, z: number): Vector3
	return self.origin + (Vector3.new(x, y, z) + Vector3.one * 0.5) * self.blockSize
end

function VoxelWorld.worldToBlock(self: VoxelWorld, position: Vector3): (number, number, number)
	local local_ = (position - self.origin) / self.blockSize
	return math.floor(local_.X), math.floor(local_.Y), math.floor(local_.Z)
end

-- stacks several layers (octaves) of roblox's perlin noise, every layer is twice as detailed but half as strong
-- that gives big smooth shapes with small bumps on top, instead of boring blobs
-- scale = how big the biggest shapes are in blocks, offset = the seed, so every world is different
local function fractalNoise(x: number, z: number, offset: number, scale: number, octaves: number): number
	local total, amplitude, frequency, range = 0, 1, 1 / scale, 0
	for _ = 1, octaves do
		-- the offset trick in the 3rd argument shifts every call to another spot in the noise, so different seeds don't look alike
		total += math.noise(x * frequency + offset, z * frequency - offset * 0.7, offset * 0.3) * amplitude
		range += amplitude -- adds up the max possible value so we can divide it back to roughly -1 to 1
		amplitude *= 0.5
		frequency *= 2
	end
	return math.clamp(total / range * 2, -1, 1) -- perlin rarely reaches the edges, so * 2 stretches it out a bit
end

-- 3 noise layers combined into one height per column
function VoxelWorld.terrainHeight(self: VoxelWorld, x: number, z: number): number
	local offset = self.noiseOffset
	local land = fractalNoise(x, z, offset, 160, 3) -- very large and smooth, the general shape of the land
	local hills = fractalNoise(x, z, offset + 101.3, 48, 4) -- smaller and bumpier, on top of the land
	-- mountains: max(0) cuts off everything below zero so they only appear in some places
	-- and squaring it below makes them stay flat/low at the foot and then shoot up quickly, which looks more like mountains
	local peaks = math.max(0, fractalNoise(x, z, offset + 217.9, 110, 3) + 0.15)
	local headroom = self.height - self.seaLevel -- how much room there is above the water for mountains to grow
	local surface = self.seaLevel + 2 + land * 12 + hills * 5 + peaks * peaks * headroom * 0.9
	return math.clamp(math.floor(surface), 1, self.height - 10) -- leave room for trees
end

-- goes through every column and fills it from the bottom up: stone, then 3 layers of dirt (or sand), then the surface block
-- anything under sea level that isn't land gets filled with water
function VoxelWorld.fillTerrain(self: VoxelWorld)
	local snowLine = self.seaLevel + (self.height - self.seaLevel) * 0.55 -- above this it's snow, 55% of the way up from the sea
	for x = 0, self.size - 1 do
		for z = 0, self.size - 1 do
			local top = self:terrainHeight(x, z)
			local beach = top <= self.seaLevel + 1 -- land right at the waterline becomes sand
			local surface = if beach then Blocks.Sand elseif top > snowLine then Blocks.Snow else Blocks.Grass
			local under = if beach then Blocks.Sand else Blocks.Dirt
			for y = 0, math.max(top, self.seaLevel) do -- goes up to sea level even if the land is lower, that's where the water goes
				local block = if y > top
					then Blocks.Water
					elseif y == top then surface
					elseif y > top - 4 then under
					else Blocks.Stone
				self:writeBlock(x, y, z, block)
			end
		end
	end
end

-- a trunk of 4 to 6 blocks with leaves around the top: 3 wide layers (5x5) at the bottom, 1 small layer (3x3) on top
function VoxelWorld.placeTree(self: VoxelWorld, x: number, ground: number, z: number, random: Random)
	local trunk = random:NextInteger(4, 6)
	local top = ground + trunk
	for y = ground + 1, top do
		self:writeBlock(x, y, z, Blocks.Wood)
	end
	for dy = -2, 1 do -- leaf layers relative to the top of the trunk
		local radius = if dy < 0 then 2 else 1
		for dx = -radius, radius do
			for dz = -radius, radius do
				local corner = math.abs(dx) == radius and math.abs(dz) == radius
				-- corners are always skipped on the top layer and 50% of the time on the others, makes trees round and not all the same
				if corner and (dy == 1 or random:NextNumber() < 0.5) then
					continue
				end
				if self:getBlock(x + dx, top + dy, z + dz) == Blocks.Air then -- only fill air, so leaves never replace the trunk
					self:writeBlock(x + dx, top + dy, z + dz, Blocks.Leaves)
				end
			end
		end
	end
end

-- uses the seed for the random too, so the same seed always gives the same trees
function VoxelWorld.plantTrees(self: VoxelWorld)
	local random = Random.new(self.seed)
	-- stays 2 blocks away from the edge so leaves never go outside the world
	for x = 2, self.size - 3 do
		for z = 2, self.size - 3 do
			if random:NextNumber() > 0.012 then -- roughly 1.2% of the columns try to get a tree
				continue
			end
			local ground = self:surfaceHeight(x, z)
			if ground >= 0 and self:getBlock(x, ground, z) == Blocks.Grass then -- trees only grow on grass, not sand, snow or underwater
				self:placeTree(x, ground, z, random)
			end
		end
	end
end

-- builds the whole world: data first (terrain, trees), then meshes. Yields until all chunks are drawn
function VoxelWorld.generate(self: VoxelWorld): ()
	buffer.fill(self.blocks, 0, 0)
	self:fillTerrain()
	if self.trees then
		self:plantTrees()
	end
	self.generated = true -- from here on setBlock is allowed to redraw chunks
	local chunks = self.size // CHUNK_SIZE
	-- every drawChunk yields while baking, so running a few at once instead of one after another is much faster
	local total = chunks * chunks
	local nextChunk, finished, workers = 0, 0, math.min(8, total)
	local waiting = coroutine.running()
	for _ = 1, workers do
		task.spawn(function()
			while nextChunk < total do
				local index = nextChunk
				nextChunk += 1
				self:drawChunk(index // chunks, index % chunks)
			end
			finished += 1
			if finished == workers and coroutine.status(waiting) == "suspended" then
				task.spawn(waiting)
			end
		end)
	end
	if finished < workers then
		coroutine.yield()
	end
end

-- decides if a face is worth drawing. Faces between two solid blocks can never be seen, so skipping them is what keeps meshes small
-- block = the block the face belongs to, neighbour = what is on the other side of that face
local function isVisibleFace(block: BlockInfo, neighbour: number): boolean
	if neighbour == Blocks.Air then
		return true -- air is always visible
	end
	local other = INFO[neighbour]
	if block.water then
		return false -- water only shows against air
	end
	return not other.opaque -- solid block next to water or leaves: draw it, so you can see it through the transparent one
end

-- since we're not using textures, we make the blocks slightly colored differently, so you can actually see something
local function jitterOf(x: number, y: number, z: number): number
	local hash = (x * 73856093 + y * 19349663 + z * 83492791) % 1000003 -- this basically creates a unique key for every coordinate, seemingly random but deterministic
	return hash % JITTER_LEVELS
end

-- builds one layer (blocks or water) of a chunk into an EditableMesh. Returns nil when it has no faces.
-- this is the heart of the whole thing: it loops over every block of the chunk and only adds the faces you could actually see
-- everything is built in one editablemesh, then drawChunk bakes it. Water is a separate mesh so it can be transparent
function VoxelWorld.buildMesh(self: VoxelWorld, chunkX: number, chunkZ: number, water: boolean): EditableMesh?
	local editable = AssetService:CreateEditableMesh()
	local half = Vector3.new(CHUNK_SIZE, self.height, CHUNK_SIZE) * self.blockSize / 2 -- half the size of the chunk box, vertices are placed relative to its centre
	-- only 6 normals exist (one per direction) and we reuse them for every face, same for the uv, saves a lot of memory
	local normalIds = {}
	for direction, face in FACES do
		normalIds[direction] = editable:AddNormal(face.normal)
	end
	local uv = editable:AddUV(Vector2.zero) -- no textures, so every face just points at the same uv
	-- a mesh color is only added the first time it's needed, after that we reuse its id
	-- the key is a unique number for the combination of block, direction and jitter
	local colorIds: { [number]: number } = {}
	local function colorIdOf(block: number, direction: number, jitter: number): number
		local key = (block * 6 + direction) * JITTER_LEVELS + jitter
		local id = colorIds[key]
		if not id then
			local face = FACES[direction]
			local info = INFO[block]
			local base = if face.side == "top" then info.top elseif face.side == "bottom" then info.bottom else info.side
			local brightness = face.shade * (0.94 + jitter * 0.04) -- fake lighting per direction + the tiny random variation
			id = editable:AddColor(base:Lerp(Color3.new(), 1 - brightness), 1) -- lerping to black makes it darker
			colorIds[key] = id
		end
		return id
	end

	local vertices, faces = 0, 0 -- vertices is counted for the limit, faces to know if the mesh is empty
	-- adds one face (4 vertices + 2 triangles) to the mesh, pulled out of the loops below so those don't get too deep
	-- returns false when the vertex limit is reached, so the caller knows to stop
	local function addFace(block: number, direction: number, cell: Vector3, drop: number, jitter: number): boolean
		-- a face needs 4 vertices, so stop before we pass the limit
		if vertices + 4 > MAX_VERTICES then
			return false
		end
		local face = FACES[direction]
		local ids: { number } = {} -- 4 corners of the face: start at the origin and walk along u and v (0 or 1 steps)
		for corner, along in CORNERS do
			local point = face.origin + face.u * along[1] + face.v * along[2]
			if point.Y == 1 then -- only the points at the top of the block get lowered, so the water surface sits lower
				point -= Vector3.new(0, drop, 0)
			end
			ids[corner] = editable:AddVertex((cell + point) * self.blockSize - half)
		end
		vertices += 4
		local color = colorIdOf(block, direction, jitter)
		local normal = normalIds[direction]
		for _, triangle in TRIANGLES do -- a face is 2 triangles, and roblox wants colors/normals/uvs per triangle corner, so we give the same one 3 times
			local faceId = editable:AddTriangle(ids[triangle[1]], ids[triangle[2]], ids[triangle[3]])
			editable:SetFaceUVs(faceId, { uv, uv, uv })
			editable:SetFaceNormals(faceId, { normal, normal, normal })
			editable:SetFaceColors(faceId, { color, color, color })
		end
		faces += 1
		return true
	end

	local startX, startZ = chunkX * CHUNK_SIZE, chunkZ * CHUNK_SIZE -- world coords of the corner of this chunk
	for y = 0, self.height - 1 do
		for localZ = 0, CHUNK_SIZE - 1 do
			for localX = 0, CHUNK_SIZE - 1 do
				local x, z = startX + localX, startZ + localZ
				local block = buffer.readu8(self.blocks, (y * self.size + z) * self.size + x)
				if block == Blocks.Air then
					continue
				end
				local info = INFO[block]
				if info.water ~= water then
					continue
				end
				-- An exposed water surface sits a little lower, so shores and waterfalls read as water.
				local drop = if water and self:getBlock(x, y + 1, z) ~= Blocks.Water then WATER_DROP else 0
				local cell = Vector3.new(localX, y, localZ) -- position inside the chunk, in blocks
				for direction, face in FACES do
					local offset = face.offset
					if y == 0 and direction == 4 then
						continue -- nobody sees the world's underside
					end
					local neighbour = self:getBlock(x + offset.X, y + offset.Y, z + offset.Z)
					if not isVisibleFace(info, neighbour) then
						continue
					end
					if not addFace(block, direction, cell, drop, jitterOf(x, y, z)) then
						warn(`[VoxelWorld] chunk {chunkX},{chunkZ} over the vertex limit; clipped`)
						break
					end
				end
			end
		end
	end
	if faces == 0 then
		editable:Destroy() -- always clean up, editablemeshes count against that tiny memory limit until they're destroyed
		return nil
	end
	-- Two tiny triangles in opposite corners pin the bounds to the whole chunk box, so the mesh's centre is the
	-- chunk's centre whether Roblox places a part by mesh origin or bounds centre.
	for _, corner in { -half, half } do
		local towards = if corner == half then -0.01 else 0.01
		local a = editable:AddVertex(corner)
		local b = editable:AddVertex(corner + Vector3.new(towards, 0, 0))
		local c = editable:AddVertex(corner + Vector3.new(0, towards, 0))
		local faceId = editable:AddTriangle(a, b, c)
		editable:SetFaceUVs(faceId, { uv, uv, uv })
	end
	return editable
end

-- bakes the editablemesh into plain mesh content (baked content doesn't count against the small
-- editable mesh memory budget), then makes an anchored, colliding part from it.
local function bake(editable: EditableMesh): MeshPart
	local result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(editable))
	if result ~= Enum.CreateContentResult.Success then
		error(`CreateDataModelContentAsync returned {result}`)
	end
	local part = AssetService:CreateMeshPartAsync(content, {
		CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition,
		-- very unoptimized built-in collision, main version solves this with two things:
		-- 1) custom character
		-- 2) skipping roblox physics entirely
		RenderFidelity = Enum.RenderFidelity.Precise,
	})
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Plastic
	part.Color = Color3.new(1, 1, 1)
	return part
end

-- (Re)draws both layers of one chunk; the new parts go in before the old ones leave. Yields.
-- order is: build the mesh, bake it, parent the new part, and only then destroy the old one, so there's never a flicker or hole when you break a block
function VoxelWorld.drawChunk(self: VoxelWorld, chunkX: number, chunkZ: number): ()
	local chunks = self.size // CHUNK_SIZE
	if chunkX < 0 or chunkZ < 0 or chunkX >= chunks or chunkZ >= chunks then
		return
	end
	-- every mesh is built around its own centre (see the bounds trick in buildMesh), so the part just goes at the middle of the chunk
	local centre = self.origin
		+ Vector3.new((chunkX + 0.5) * CHUNK_SIZE, self.height / 2, (chunkZ + 0.5) * CHUNK_SIZE) * self.blockSize
	for _, water in { false, true } do
		local key = `{chunkX},{chunkZ},{if water then "water" else "blocks"}`
		local editable = self:buildMesh(chunkX, chunkZ, water)
		local part: MeshPart? = nil
		if editable then
			local ok, made = pcall(bake, editable) -- pcall so one failed bake doesn't kill the other chunks
			editable:Destroy()
			if ok then
				part = made
			else
				warn(`[VoxelWorld] baking chunk {key} failed: {made}`)
			end
		end
		if part then
			part.Name = key
			part.CFrame = CFrame.new(centre)
			if water then
				part.Transparency = WATER_TRANSPARENCY
				part.CastShadow = false
			end
			part.Parent = self.folder
		end
		local old = self.parts[key]
		if old then
			old:Destroy()
		end
		self.parts[key] = part
	end
end

function VoxelWorld.destroy(self: VoxelWorld): () -- cleanup, destroying the parts in the workspace
	self.folder:Destroy()
	table.clear(self.parts)
	self.generated = false
end

return VoxelWorld
