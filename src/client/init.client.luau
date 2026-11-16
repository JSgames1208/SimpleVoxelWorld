const ReplicatedStorage = game:GetService("ReplicatedStorage")
const VoxelWorld = require(ReplicatedStorage.Shared.VoxelWorld)

local world = VoxelWorld.new({ seed = 42, sizeInChunks = 6 })
world:generate()
