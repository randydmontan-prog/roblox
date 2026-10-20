--!strict
--[[
	TestSetup
	=========
	Builds a small sandbox on server start so the possession loop can be
	tested straight away in Studio (Play / Play Here / Start Server):

	  * Security Guard, Mechanic (and optionally Brawler) NPCs tagged GhostNPC.
	  * A SecurityDoor set into a wall (open it with the Guard's [Q]).
	  * A BrokenGenerator (repair it with the Mechanic's [Q]).
	  * An optional training dummy for the Brawler's [LeftClick].

	Dead or removed NPCs respawn at their original spot. Disable the whole
	thing with PossessionConfig.TestEnvironment.Enabled = false.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PossessionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PossessionConfig"))

type NpcClassConfig = PossessionConfig.NpcClassConfig

local TestConfig = PossessionConfig.TestEnvironment
local Tags = PossessionConfig.Tags
local Attributes = PossessionConfig.Attributes

if not TestConfig.Enabled then
	return
end

local FOLDER_NAME = "BorrowedBodyTestEnvironment"
local SKIN_COLOR = Color3.fromRGB(234, 184, 146)

local previous = workspace:FindFirstChild(FOLDER_NAME)
if previous then
	previous:Destroy()
end

local folder = Instance.new("Folder")
folder.Name = FOLDER_NAME
folder.Parent = workspace

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function makePart(
	name: string,
	parent: Instance,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function makeBillboard(adornee: BasePart, text: string, offset: Vector3, color: Color3): TextLabel
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(220, 40)
	billboard.StudsOffset = offset
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 80
	billboard.Adornee = adornee
	billboard.Parent = adornee

	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextColor3 = color
	textLabel.TextStrokeTransparency = 0.3
	textLabel.TextScaled = true
	textLabel.Font = Enum.Font.GothamBold
	textLabel.Parent = billboard
	return textLabel
end

local function makeSign(text: string, position: Vector3, color: Color3)
	local anchor = makePart("Sign", folder, Vector3.one, CFrame.new(position), color, Enum.Material.SmoothPlastic)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	makeBillboard(anchor, text, Vector3.zero, color)
end

--------------------------------------------------------------------------------
-- World basics
--------------------------------------------------------------------------------

if not workspace:FindFirstChild("Baseplate") then
	local baseplate = makePart(
		"Baseplate",
		workspace,
		Vector3.new(512, 1, 512),
		CFrame.new(0, -0.5, 0),
		Color3.fromRGB(99, 95, 98),
		Enum.Material.Concrete
	)
	baseplate.Locked = true
end

local hasSpawn = false
for _, descendant in workspace:GetDescendants() do
	if descendant:IsA("SpawnLocation") then
		hasSpawn = true
		break
	end
end
if not hasSpawn then
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "GhostSpawn"
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.CFrame = CFrame.new(0, 0.5, 10)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Color = PossessionConfig.Ghost.Tint
	spawn.Material = Enum.Material.Neon
	spawn.Transparency = 0.4
	spawn.Parent = folder
end

--------------------------------------------------------------------------------
-- NPC rigs
--------------------------------------------------------------------------------

-- Simple welded block rig, used when avatar assets can't be loaded.
local function buildFallbackRig(accent: Color3, secondary: Color3): Model
	local model = Instance.new("Model")

	local hipHeight = 2
	local rootY = hipHeight + 1

	local root = makePart("HumanoidRootPart", model, Vector3.new(2, 2, 1), CFrame.new(0, rootY, 0), accent, Enum.Material.SmoothPlastic)
	root.Transparency = 1
	root.Anchored = false
	model.PrimaryPart = root

	local function limb(name: string, size: Vector3, offset: Vector3, color: Color3)
		local part = makePart(name, model, size, CFrame.new(offset + Vector3.new(0, rootY, 0)), color, Enum.Material.SmoothPlastic)
		part.Anchored = false
		part.Massless = true
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
	end

	limb("UpperTorso", Vector3.new(2, 2, 1), Vector3.zero, accent)
	limb("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 1.6, 0), SKIN_COLOR)
	limb("LeftArm", Vector3.new(1, 2, 1), Vector3.new(-1.5, 0, 0), SKIN_COLOR)
	limb("RightArm", Vector3.new(1, 2, 1), Vector3.new(1.5, 0, 0), SKIN_COLOR)
	limb("LeftLeg", Vector3.new(1, 2, 1), Vector3.new(-0.5, -2, 0), secondary)
	limb("RightLeg", Vector3.new(1, 2, 1), Vector3.new(0.5, -2, 0), secondary)

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = hipHeight
	humanoid.RequiresNeck = false
	humanoid.Parent = model

	local animator = Instance.new("Animator")
	animator.Parent = humanoid

	return model
end

local function buildRig(accent: Color3, secondary: Color3): Model
	local ok, result = pcall(function(): Model
		local description = Instance.new("HumanoidDescription")
		description.HeadColor = SKIN_COLOR
		description.LeftArmColor = SKIN_COLOR
		description.RightArmColor = SKIN_COLOR
		description.TorsoColor = accent
		description.LeftLegColor = secondary
		description.RightLegColor = secondary
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if ok and result then
		return result
	end
	warn(`[TestSetup] Falling back to block rig: {result}`)
	return buildFallbackRig(accent, secondary)
end

local function spawnNpc(classConfig: NpcClassConfig, cframe: CFrame)
	local model = buildRig(classConfig.AccentColor, classConfig.SecondaryColor)
	model.Name = `{classConfig.DisplayName} NPC`
	model:SetAttribute(Attributes.NPCClass, classConfig.Id)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		makeBillboard(head, classConfig.DisplayName, Vector3.new(0, 2.5, 0), classConfig.AccentColor:Lerp(Color3.new(1, 1, 1), 0.4))
	end

	model:PivotTo(cframe)
	model.Parent = folder
	-- Tag last so PossessionService sees a fully built, parented model.
	CollectionService:AddTag(model, Tags.GhostNPC)

	local respawning = false
	local function respawn()
		if respawning then
			return
		end
		respawning = true
		task.delay(TestConfig.NpcRespawnDelay, function()
			if model.Parent then
				model:Destroy()
			end
			if folder.Parent then
				spawnNpc(classConfig, cframe)
			end
		end)
	end

	if humanoid then
		humanoid.Died:Connect(respawn)
	end
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			respawn()
		end
	end)
end

local function spawnTrainingDummy(cframe: CFrame)
	local model = buildFallbackRig(Color3.fromRGB(150, 120, 80), Color3.fromRGB(90, 70, 50))
	model.Name = "Training Dummy"
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = 200
		humanoid.Health = 200
		humanoid.WalkSpeed = 0
		humanoid.JumpHeight = 0
		humanoid.Died:Connect(function()
			task.delay(TestConfig.NpcRespawnDelay, function()
				model:Destroy()
				if folder.Parent then
					spawnTrainingDummy(cframe)
				end
			end)
		end)
	end
	model:PivotTo(cframe)
	model.Parent = folder
end

--------------------------------------------------------------------------------
-- Security door (Guard)
--------------------------------------------------------------------------------

local function buildSecurityDoor(origin: CFrame)
	local model = Instance.new("Model")
	model.Name = "SecurityDoor"

	local metal = Color3.fromRGB(70, 74, 82)
	local wallColor = Color3.fromRGB(120, 124, 130)
	local height = 10
	local opening = 6

	-- Walls either side of the opening. The panel slides into the right-hand wall.
	makePart("WallLeft", model, Vector3.new(24, height, 1), origin * CFrame.new(-(opening / 2 + 12), height / 2, 0), wallColor, Enum.Material.Concrete)
	makePart("WallRight", model, Vector3.new(24, height, 1), origin * CFrame.new(opening / 2 + 12, height / 2, 0), wallColor, Enum.Material.Concrete)
	makePart("Lintel", model, Vector3.new(opening, 1, 1), origin * CFrame.new(0, height - 0.5, 0), metal, Enum.Material.DiamondPlate)

	local panel = makePart(
		PossessionConfig.Door.PanelName,
		model,
		Vector3.new(opening, height - 1, 0.6),
		origin * CFrame.new(0, (height - 1) / 2, 0),
		Color3.fromRGB(150, 40, 40),
		Enum.Material.Metal
	)
	model.PrimaryPart = panel

	local light = makePart(
		PossessionConfig.Door.StatusLightName,
		model,
		Vector3.new(1.2, 0.4, 0.2),
		origin * CFrame.new(opening / 2 + 1.2, 5, -0.6),
		PossessionConfig.Door.LockedColor,
		Enum.Material.Neon
	)
	makeBillboard(light, "SECURITY DOOR · Guard [Q]", Vector3.new(0, 4, 0), Color3.fromRGB(255, 220, 120))

	model.Parent = folder
	CollectionService:AddTag(model, Tags.SecurityDoor)

	-- A reward pad behind the door so there's something to reach.
	local pad = makePart("VaultPad", folder, Vector3.new(6, 0.4, 6), origin * CFrame.new(0, 0.2, -8), Color3.fromRGB(255, 200, 60), Enum.Material.Neon)
	makeBillboard(pad, "VAULT", Vector3.new(0, 3, 0), Color3.fromRGB(255, 220, 120))
end

--------------------------------------------------------------------------------
-- Broken generator (Mechanic)
--------------------------------------------------------------------------------

local function buildBrokenGenerator(origin: CFrame)
	local model = Instance.new("Model")
	model.Name = "BrokenGenerator"

	local base = makePart("Base", model, Vector3.new(6, 3, 4), origin * CFrame.new(0, 1.5, 0), Color3.fromRGB(60, 64, 60), Enum.Material.DiamondPlate)
	model.PrimaryPart = base

	local core = makePart(
		PossessionConfig.Generator.CoreName,
		model,
		Vector3.new(2, 2, 2),
		origin * CFrame.new(0, 4, 0),
		PossessionConfig.Generator.BrokenColor,
		Enum.Material.Neon
	)
	core.Shape = Enum.PartType.Ball

	makePart("Exhaust", model, Vector3.new(0.8, 3, 0.8), origin * CFrame.new(2, 4.5, 1), Color3.fromRGB(40, 40, 40), Enum.Material.Metal)

	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(60, 60, 60)
	smoke.Opacity = 0.25
	smoke.RiseVelocity = 4
	smoke.Size = 3
	smoke.Parent = core

	local light = Instance.new("PointLight")
	light.Color = PossessionConfig.Generator.RepairedColor
	light.Range = 16
	light.Brightness = 2
	light.Enabled = false
	light.Parent = core

	local status = makeBillboard(core, "BROKEN · 0%", Vector3.new(0, 3, 0), Color3.fromRGB(255, 120, 110))
	local function refreshStatus()
		local progress = model:GetAttribute(Attributes.RepairProgress)
		local percent = if type(progress) == "number" then math.floor(progress) else 0
		if model:GetAttribute(Attributes.Repaired) == true then
			status.Text = "ONLINE ✔"
			status.TextColor3 = PossessionConfig.Generator.RepairedColor
		else
			status.Text = `BROKEN · {percent}%  (Mechanic [Q])`
		end
	end
	model:GetAttributeChangedSignal(Attributes.RepairProgress):Connect(refreshStatus)
	model:GetAttributeChangedSignal(Attributes.Repaired):Connect(refreshStatus)
	refreshStatus()

	model:SetAttribute(Attributes.RepairProgress, 0)
	model.Parent = folder
	CollectionService:AddTag(model, Tags.BrokenGenerator)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local facingSpawn = CFrame.Angles(0, math.pi, 0)
local classes = PossessionConfig.Classes

spawnNpc(classes.SecurityGuard, CFrame.new(-8, 3, -14) * facingSpawn)
spawnNpc(classes.Mechanic, CFrame.new(8, 3, -14) * facingSpawn)
if TestConfig.SpawnBrawler then
	spawnNpc(classes.Brawler, CFrame.new(0, 3, -20) * facingSpawn)
end
if TestConfig.SpawnTrainingDummy then
	spawnTrainingDummy(CFrame.new(-26, 3, -20))
	makeSign("Brawler training dummy · [LeftClick]", Vector3.new(-26, 9, -20), Color3.fromRGB(255, 150, 150))
end

buildSecurityDoor(CFrame.new(0, 0, -44))
buildBrokenGenerator(CFrame.new(28, 0, -20))

makeSign("Ghost: [E] near a body to possess", Vector3.new(0, 8, -2), PossessionConfig.Ghost.Tint)

print("[TestSetup] Borrowed Body test environment ready.")
