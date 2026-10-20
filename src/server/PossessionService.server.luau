--!strict
--[[
	PossessionService
	=================
	Server-authoritative possession framework for "Borrowed Body".

	Responsibilities:
	  * Owns the possession RemoteEvents and validates every request.
	  * Spawns players as ghosts (CharacterAutoLoads is disabled; this service
	    controls every LoadCharacter call).
	  * Swaps Player.Character between the ghost and a possessed NPC, hands the
	    NPC assembly's network ownership to the possessing player and takes it
	    back on ejection.
	  * Runs possession stamina timers, re-possession cooldowns, ability
	    cooldowns and a lightweight host speed check.
	  * Executes class abilities: keycard doors, generator repair, melee.

	State that the HUD needs is replicated through Player attributes (see
	PossessionConfig.Attributes) so late-joining client scripts never miss it.
]]

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local PossessionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PossessionConfig"))

type NpcClassConfig = PossessionConfig.NpcClassConfig
type AbilityConfig = PossessionConfig.AbilityConfig
type AbilitySlot = PossessionConfig.AbilitySlot

local Tags = PossessionConfig.Tags
local Attributes = PossessionConfig.Attributes
local Settings = PossessionConfig.Possession

type PlayerState = {
	ghost: Model?,
	npc: Model?,
	classConfig: NpcClassConfig?,
	expiresAt: number,
	repossessReadyAt: number,
	abilityReadyAt: { [AbilitySlot]: number },
	lastRequestAt: { [string]: number },
	npcConnections: { RBXScriptConnection },
	clonedAnimate: Instance?,
	-- Anti-cheat sampling of the host's position.
	lastSamplePosition: Vector3?,
	lastSampleTime: number,
	speedStrikes: number,
}

type AbilityHandler = (player: Player, npc: Model, root: BasePart, ability: AbilityConfig) -> (boolean, string)

local states: { [Player]: PlayerState } = {}

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local function getOrCreateRemotesFolder(): Instance
	local existing = ReplicatedStorage:FindFirstChild(PossessionConfig.Remotes.FolderName)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = PossessionConfig.Remotes.FolderName
	folder.Parent = ReplicatedStorage
	return folder
end

local remotesFolder = getOrCreateRemotesFolder()

local function getOrCreateRemote(name: string): RemoteEvent
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end

local PossessRequest = getOrCreateRemote(PossessionConfig.Remotes.PossessRequest)
local EjectRequest = getOrCreateRemote(PossessionConfig.Remotes.EjectRequest)
local UseAbilityRequest = getOrCreateRemote(PossessionConfig.Remotes.UseAbilityRequest)
local FeedbackRemote = getOrCreateRemote(PossessionConfig.Remotes.Feedback)

local function sendFeedback(player: Player, message: string, success: boolean)
	if player.Parent then
		FeedbackRemote:FireClient(player, message, success)
	end
end

--------------------------------------------------------------------------------
-- Generic helpers
--------------------------------------------------------------------------------

local function getHumanoid(model: Model): Humanoid?
	return model:FindFirstChildOfClass("Humanoid")
end

local function getRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isAlive(model: Model): boolean
	local humanoid = getHumanoid(model)
	return humanoid ~= nil and humanoid.Health > 0 and humanoid:GetState() ~= Enum.HumanoidStateType.Dead
end

local function getNumberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return default
end

local function passesRateLimit(state: PlayerState, key: string): boolean
	local now = os.clock()
	local last = state.lastRequestAt[key]
	if last and now - last < Settings.RequestMinInterval then
		return false
	end
	state.lastRequestAt[key] = now
	return true
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- World position used for range checks on tagged interactables.
local function getInteractPosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		if instance.PrimaryPart then
			return instance.PrimaryPart.Position
		end
		return instance:GetPivot().Position
	end
	return nil
end

local function findNearestTagged(tag: string, origin: Vector3, range: number): Instance?
	local nearest: Instance? = nil
	local nearestDistance = range
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsDescendantOf(workspace) then
			local position = getInteractPosition(instance)
			if position then
				local distance = (position - origin).Magnitude
				if distance <= nearestDistance then
					nearest = instance
					nearestDistance = distance
				end
			end
		end
	end
	return nearest
end

local function setCollisionGroup(model: Model, group: string)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = group
		end
	end
end

--------------------------------------------------------------------------------
-- Collision groups & storage
--------------------------------------------------------------------------------

local function setupCollisionGroups()
	local groups = PossessionConfig.CollisionGroups
	for _, group in { groups.Ghost, groups.NPC } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	-- Ghosts phase through each other and through bodies, but not through world geometry.
	PhysicsService:CollisionGroupSetCollidable(groups.Ghost, groups.Ghost, false)
	PhysicsService:CollisionGroupSetCollidable(groups.Ghost, groups.NPC, false)
end

setupCollisionGroups()

-- Ghost characters are parked here (outside of replication) while their owner is possessing.
local ghostVault = Instance.new("Folder")
ghostVault.Name = "BB_GhostVault"
ghostVault.Parent = ServerStorage

--------------------------------------------------------------------------------
-- Player attribute replication
--------------------------------------------------------------------------------

local function publishState(player: Player, state: PlayerState)
	local classConfig = state.classConfig
	player:SetAttribute(Attributes.Possessing, state.npc ~= nil)
	player:SetAttribute(Attributes.ClassId, if classConfig then classConfig.Id else nil)
	player:SetAttribute(Attributes.Duration, if classConfig then classConfig.Duration else nil)
	player:SetAttribute(Attributes.ExpiresAt, if state.npc then state.expiresAt else nil)
	player:SetAttribute(Attributes.RepossessReadyAt, state.repossessReadyAt)
	for _, slot in PossessionConfig.AbilitySlots do
		player:SetAttribute(PossessionConfig.AbilityReadyAttribute(slot), state.abilityReadyAt[slot] or 0)
	end
end

--------------------------------------------------------------------------------
-- NPC registration
--------------------------------------------------------------------------------

local function releaseNetworkOwnership(root: BasePart)
	if root:IsDescendantOf(workspace) and not root.Anchored then
		local canSet = root:CanSetNetworkOwnership()
		if canSet then
			-- Idle NPCs are server-owned so exploiters cannot fling bodies they don't control.
			root:SetNetworkOwner(nil)
		end
	end
end

local function registerNpc(instance: Instance)
	if not instance:IsA("Model") then
		warn(`[PossessionService] {instance:GetFullName()} is tagged {Tags.GhostNPC} but is not a Model`)
		return
	end

	local classConfig = PossessionConfig.GetClass(instance:GetAttribute(Attributes.NPCClass))
	if not classConfig then
		warn(`[PossessionService] {instance:GetFullName()} has unknown {Attributes.NPCClass} attribute`)
		return
	end

	local humanoidInstance = instance:FindFirstChildOfClass("Humanoid") or instance:WaitForChild("Humanoid", 5)
	local rootInstance = instance:FindFirstChild("HumanoidRootPart") or instance:WaitForChild("HumanoidRootPart", 5)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		warn(`[PossessionService] {instance:GetFullName()} is missing a Humanoid`)
		return
	end
	if not rootInstance or not rootInstance:IsA("BasePart") then
		warn(`[PossessionService] {instance:GetFullName()} is missing a HumanoidRootPart`)
		return
	end
	local humanoid: Humanoid = humanoidInstance
	local root: BasePart = rootInstance

	humanoid.MaxHealth = classConfig.MaxHealth
	humanoid.Health = classConfig.MaxHealth
	humanoid.WalkSpeed = classConfig.IdleWalkSpeed
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = classConfig.JumpHeight

	setCollisionGroup(instance, PossessionConfig.CollisionGroups.NPC)
	releaseNetworkOwnership(root)
end

for _, instance in CollectionService:GetTagged(Tags.GhostNPC) do
	task.spawn(registerNpc, instance)
end
CollectionService:GetInstanceAddedSignal(Tags.GhostNPC):Connect(registerNpc)

--------------------------------------------------------------------------------
-- Ghost form
--------------------------------------------------------------------------------

local function applyGhostVisual(instance: Instance)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = PossessionConfig.CollisionGroups.Ghost
		instance.CastShadow = false
		instance.Massless = instance.Name ~= "HumanoidRootPart"
		if instance.Name ~= "HumanoidRootPart" then
			instance.Transparency = math.max(instance.Transparency, PossessionConfig.Ghost.Transparency)
		end
	elseif instance:IsA("Decal") then
		instance.Transparency = math.max(instance.Transparency, PossessionConfig.Ghost.Transparency)
	end
end

local function setupGhost(player: Player, character: Model)
	character:SetAttribute(Attributes.IsGhost, true)

	local humanoidInstance = character:WaitForChild("Humanoid", 10)
	if not (humanoidInstance and humanoidInstance:IsA("Humanoid")) then
		warn(`[PossessionService] Ghost for {player.Name} has no Humanoid`)
		return
	end
	local humanoid: Humanoid = humanoidInstance

	humanoid.WalkSpeed = PossessionConfig.Ghost.WalkSpeed
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	-- Invisible ForceField: ghosts are intangible and cannot be damaged.
	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	local highlight = Instance.new("Highlight")
	highlight.Name = "GhostAura"
	highlight.FillColor = PossessionConfig.Ghost.Tint
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = PossessionConfig.Ghost.Tint
	highlight.OutlineTransparency = 0.2
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = character

	for _, descendant in character:GetDescendants() do
		applyGhostVisual(descendant)
	end
	-- Accessories and clothing stream in after CharacterAdded.
	character.DescendantAdded:Connect(applyGhostVisual)

	humanoid.Died:Connect(function()
		task.delay(PossessionConfig.Ghost.RespawnDelay, function()
			if player.Parent and player.Character == character then
				player:LoadCharacter()
			end
		end)
	end)
end

--------------------------------------------------------------------------------
-- Possession lifecycle
--------------------------------------------------------------------------------

-- Hands the NPC back to the server. Does not touch the ghost or Player.Character.
local function releaseNpc(state: PlayerState): Model?
	local npc = state.npc
	if not npc then
		return nil
	end

	disconnectAll(state.npcConnections)
	state.npc = nil
	state.classConfig = nil
	state.lastSamplePosition = nil
	state.speedStrikes = 0

	if state.clonedAnimate then
		state.clonedAnimate:Destroy()
		state.clonedAnimate = nil
	end

	npc:SetAttribute(Attributes.PossessedBy, nil)

	local humanoid = getHumanoid(npc)
	local classConfig = PossessionConfig.GetClass(npc:GetAttribute(Attributes.NPCClass))
	if humanoid and humanoid.Health > 0 then
		humanoid:Move(Vector3.zero)
		humanoid.WalkSpeed = if classConfig then classConfig.IdleWalkSpeed else 8
	end

	local root = getRoot(npc)
	if root then
		releaseNetworkOwnership(root)
	end

	return npc
end

local function restoreGhost(player: Player, state: PlayerState, exitCFrame: CFrame?)
	local ghost = state.ghost
	if ghost and ghost:IsDescendantOf(ghostVault) and isAlive(ghost) then
		if exitCFrame then
			ghost:PivotTo(exitCFrame)
		end
		for _, descendant in ghost:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.AssemblyLinearVelocity = Vector3.zero
				descendant.AssemblyAngularVelocity = Vector3.zero
			end
		end
		ghost.Parent = workspace
		player.Character = ghost
	else
		-- The ghost was lost (destroyed, died, ...). Spawn a fresh one at the exit point.
		if ghost then
			ghost:Destroy()
		end
		state.ghost = nil
		task.spawn(function()
			if not player.Parent then
				return
			end
			player:LoadCharacter()
			local character = player.Character
			if exitCFrame and character and states[player] == state then
				character:PivotTo(exitCFrame)
			end
		end)
	end
end

local function eject(player: Player, reason: string): boolean
	local state = states[player]
	if not state or not state.npc then
		return false
	end

	local npc = state.npc
	local root = getRoot(npc)
	local exitCFrame: CFrame? = nil
	if root and root:IsDescendantOf(workspace) then
		local position = root.Position + Vector3.new(0, Settings.EjectHeightOffset, 0)
		local look = root.CFrame.LookVector
		exitCFrame = CFrame.lookAt(position, position + Vector3.new(look.X, 0, look.Z))
	end

	releaseNpc(state)
	restoreGhost(player, state, exitCFrame)

	state.repossessReadyAt = serverNow() + Settings.RepossessCooldown
	publishState(player, state)
	sendFeedback(player, reason, false)
	return true
end

local function tryPossess(player: Player, target: unknown): (boolean, string?)
	local state = states[player]
	if not state then
		return false, nil
	end
	if state.npc then
		return false, "You are already possessing a body."
	end

	local now = serverNow()
	if now < state.repossessReadyAt then
		return false, string.format("Your spirit is recovering (%.1fs).", state.repossessReadyAt - now)
	end

	-- Validate the untrusted target.
	if typeof(target) ~= "Instance" then
		return false, nil
	end
	if not target:IsA("Model") then
		return false, nil
	end
	local npc: Model = target
	if not CollectionService:HasTag(npc, Tags.GhostNPC) or not npc:IsDescendantOf(workspace) then
		return false, nil
	end

	local classConfig = PossessionConfig.GetClass(npc:GetAttribute(Attributes.NPCClass))
	local humanoid = getHumanoid(npc)
	local npcRoot = getRoot(npc)
	if not classConfig or not humanoid or not npcRoot then
		return false, nil
	end
	if not isAlive(npc) then
		return false, "That body can no longer be used."
	end
	if npc:GetAttribute(Attributes.PossessedBy) ~= nil then
		return false, "Someone else is already in that body."
	end
	if npcRoot.Anchored then
		return false, "That body is pinned in place."
	end

	-- The player must currently be a living ghost.
	local ghost = player.Character
	if not ghost or ghost ~= state.ghost or ghost:GetAttribute(Attributes.IsGhost) ~= true or not isAlive(ghost) then
		return false, "Only a ghost can possess a body."
	end
	local ghostRoot = getRoot(ghost)
	if not ghostRoot then
		return false, nil
	end

	-- Server-side distance validation (anti-exploit).
	local distance = (ghostRoot.Position - npcRoot.Position).Magnitude
	if distance >= Settings.MaxDistance then
		return false, "Too far away to possess."
	end

	-- Commit.
	npc:SetAttribute(Attributes.PossessedBy, player.UserId)
	state.npc = npc
	state.classConfig = classConfig
	state.expiresAt = now + classConfig.Duration
	state.lastSamplePosition = npcRoot.Position
	state.lastSampleTime = os.clock()
	state.speedStrikes = 0
	table.clear(state.abilityReadyAt)

	humanoid.WalkSpeed = classConfig.WalkSpeed
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = classConfig.JumpHeight

	-- Give the host the player's animation script so it animates while controlled.
	if not npc:FindFirstChild("Animate") then
		local animate = ghost:FindFirstChild("Animate")
		if animate then
			local clone = animate:Clone()
			clone.Parent = npc
			state.clonedAnimate = clone
		end
	end

	player.Character = npc
	ghost.Parent = ghostVault

	local canSet, reason = npcRoot:CanSetNetworkOwnership()
	if canSet then
		npcRoot:SetNetworkOwner(player)
	else
		warn(`[PossessionService] Cannot transfer ownership of {npc:GetFullName()}: {reason}`)
	end

	table.insert(
		state.npcConnections,
		humanoid.Died:Connect(function()
			eject(player, "Your host was knocked out!")
		end)
	)
	table.insert(
		state.npcConnections,
		npc.AncestryChanged:Connect(function()
			if not npc:IsDescendantOf(workspace) then
				eject(player, "Your host vanished.")
			end
		end)
	)

	publishState(player, state)
	return true, nil
end

--------------------------------------------------------------------------------
-- Abilities
--------------------------------------------------------------------------------

local doorClosedCFrames: { [BasePart]: CFrame } = {}

local function getDoorPanel(door: Instance): BasePart?
	if door:IsA("BasePart") then
		return door
	end
	local panel = door:FindFirstChild(PossessionConfig.Door.PanelName)
	if panel and panel:IsA("BasePart") then
		return panel
	end
	if door:IsA("Model") and door.PrimaryPart then
		return door.PrimaryPart
	end
	return nil
end

local function setDoorLight(door: Instance, color: Color3)
	local light = door:FindFirstChild(PossessionConfig.Door.StatusLightName)
	if light and light:IsA("BasePart") then
		light.Color = color
	end
end

local function openDoor(door: Instance): (boolean, string)
	if door:GetAttribute(Attributes.DoorOpen) == true then
		return false, "That door is already open."
	end
	local panel = getDoorPanel(door)
	if not panel then
		return false, "This door's lock is broken."
	end

	-- Record the closed pose the first time this panel is opened.
	if not doorClosedCFrames[panel] then
		doorClosedCFrames[panel] = panel.CFrame
		panel.Destroying:Connect(function()
			doorClosedCFrames[panel] = nil
		end)
	end
	local closedCFrame: CFrame = doorClosedCFrames[panel]

	panel.Anchored = true
	door:SetAttribute(Attributes.DoorOpen, true)
	setDoorLight(door, PossessionConfig.Door.OpenColor)

	local tweenInfo = TweenInfo.new(PossessionConfig.Door.TweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	-- Slide sideways along the panel's own X axis, into the adjoining wall.
	local openCFrame = closedCFrame * CFrame.new(panel.Size.X, 0, 0)
	panel.CanCollide = false
	TweenService:Create(panel, tweenInfo, { CFrame = openCFrame }):Play()

	task.delay(PossessionConfig.Door.OpenDuration, function()
		if not panel:IsDescendantOf(workspace) then
			return
		end
		local closeTween = TweenService:Create(panel, tweenInfo, { CFrame = closedCFrame })
		closeTween.Completed:Once(function()
			panel.CanCollide = true
			door:SetAttribute(Attributes.DoorOpen, false)
			setDoorLight(door, PossessionConfig.Door.LockedColor)
		end)
		closeTween:Play()
	end)

	return true, "Access granted. Door unlocked."
end

local function updateGeneratorVisuals(generator: Instance, progress: number)
	local alpha = math.clamp(progress / 100, 0, 1)
	local repaired = alpha >= 1
	local core = generator:FindFirstChild(PossessionConfig.Generator.CoreName)
	if core and core:IsA("BasePart") then
		core.Color = PossessionConfig.Generator.BrokenColor:Lerp(PossessionConfig.Generator.RepairedColor, alpha)
	end
	for _, descendant in generator:GetDescendants() do
		if descendant:IsA("Smoke") or descendant:IsA("Fire") or descendant:IsA("ParticleEmitter") then
			descendant.Enabled = not repaired
		elseif descendant:IsA("Light") then
			descendant.Enabled = repaired
		end
	end
end

local function repairGenerator(generator: Instance, ability: AbilityConfig): (boolean, string)
	if generator:GetAttribute(Attributes.Repaired) == true then
		return false, "That generator is already running."
	end

	local progress = math.min(100, getNumberAttribute(generator, Attributes.RepairProgress, 0) + ability.RepairAmount)
	generator:SetAttribute(Attributes.RepairProgress, progress)
	updateGeneratorVisuals(generator, progress)

	if progress >= 100 then
		generator:SetAttribute(Attributes.Repaired, true)
		CollectionService:RemoveTag(generator, Tags.BrokenGenerator)
		CollectionService:AddTag(generator, Tags.RepairedGenerator)
		return true, "Generator repaired!"
	end
	return true, string.format("Repairing generator... %d%%", math.floor(progress))
end

local AbilityHandlers: { [string]: AbilityHandler } = {
	Keycard = function(_player, _npc, root, ability)
		local door = findNearestTagged(Tags.SecurityDoor, root.Position, ability.Range)
		if not door then
			return false, "No security door in range."
		end
		return openDoor(door)
	end,

	Repair = function(_player, _npc, root, ability)
		local generator = findNearestTagged(Tags.BrokenGenerator, root.Position, ability.Range)
		if not generator then
			return false, "No broken generator in range."
		end
		return repairGenerator(generator, ability)
	end,

	Melee = function(_player, npc, root, ability)
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { npc }

		local boxCFrame = root.CFrame * CFrame.new(0, 0, -ability.Range / 2)
		local boxSize = Vector3.new(5, 6, ability.Range)
		local parts = workspace:GetPartBoundsInBox(boxCFrame, boxSize, params)

		local struck: { [Humanoid]: boolean } = {}
		local hits = 0
		for _, part in parts do
			if hits >= ability.MaxTargets then
				break
			end
			local model = part:FindFirstAncestorOfClass("Model")
			local humanoid = if model then model:FindFirstChildOfClass("Humanoid") else nil
			if
				model
				and humanoid
				and not struck[humanoid]
				and humanoid.Health > 0
				and model:GetAttribute(Attributes.IsGhost) ~= true
			then
				struck[humanoid] = true
				hits += 1
				humanoid:TakeDamage(ability.Damage)
			end
		end

		-- A swing always consumes the cooldown, hit or miss.
		if hits == 0 then
			return true, "Your swing hits nothing."
		end
		return true, if hits == 1 then "Direct hit!" else `Hit {hits} targets!`
	end,
}

local function useAbility(player: Player, slotValue: unknown)
	local state = states[player]
	if not state or not passesRateLimit(state, "Ability") then
		return
	end

	local slot = PossessionConfig.ToAbilitySlot(slotValue)
	if not slot then
		return
	end

	local npc = state.npc
	local classConfig = state.classConfig
	if not npc or not classConfig then
		sendFeedback(player, "Ghosts can't interact with the world. Possess a body first.", false)
		return
	end

	local ability = PossessionConfig.GetAbility(classConfig, slot)
	if not ability then
		return
	end

	local now = serverNow()
	local readyAt = state.abilityReadyAt[slot] or 0
	if now < readyAt then
		return
	end

	local root = getRoot(npc)
	if not root or not isAlive(npc) then
		return
	end

	local handler = AbilityHandlers[ability.Effect]
	if not handler then
		warn(`[PossessionService] No handler for ability effect {ability.Effect}`)
		return
	end

	local consumed, message = handler(player, npc, root, ability)
	if consumed then
		state.abilityReadyAt[slot] = now + ability.Cooldown
		if ability.StaminaCost > 0 then
			state.expiresAt -= ability.StaminaCost
		end
		publishState(player, state)
	end
	sendFeedback(player, message, consumed)
end

--------------------------------------------------------------------------------
-- Player lifecycle
--------------------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	-- Player.Character is reassigned to NPCs on possession; those are not ghosts.
	if CollectionService:HasTag(character, Tags.GhostNPC) then
		return
	end
	-- A restored ghost has already been set up.
	if character:GetAttribute(Attributes.IsGhost) == true then
		return
	end

	local state = states[player]
	if not state then
		return
	end

	-- A fresh LoadCharacter while possessing (e.g. from another system) releases the host.
	if state.npc then
		releaseNpc(state)
		publishState(player, state)
	end

	if state.ghost and state.ghost ~= character then
		state.ghost:Destroy()
	end
	state.ghost = character
	setupGhost(player, character)
end

local function onPlayerAdded(player: Player)
	if states[player] then
		return
	end

	local state: PlayerState = {
		ghost = nil,
		npc = nil,
		classConfig = nil,
		expiresAt = 0,
		repossessReadyAt = 0,
		abilityReadyAt = {},
		lastRequestAt = {},
		npcConnections = {},
		clonedAnimate = nil,
		lastSamplePosition = nil,
		lastSampleTime = 0,
		speedStrikes = 0,
	}
	states[player] = state
	publishState(player, state)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	player:LoadCharacter()
end

local function onPlayerRemoving(player: Player)
	local state = states[player]
	if not state then
		return
	end
	states[player] = nil

	if state.npc then
		releaseNpc(state)
		-- Detach so the engine doesn't destroy the NPC along with the leaving player's character.
		player.Character = nil
	end
	if state.ghost then
		state.ghost:Destroy()
		state.ghost = nil
	end
end

Players.CharacterAutoLoads = false
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

--------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------

PossessRequest.OnServerEvent:Connect(function(player: Player, target: unknown)
	local state = states[player]
	if not state or not passesRateLimit(state, "Possess") then
		return
	end
	local ok, message = tryPossess(player, target)
	if ok then
		local classConfig = state.classConfig
		sendFeedback(player, if classConfig then `Possessed a {classConfig.DisplayName}.` else "Possessed.", true)
	elseif message then
		sendFeedback(player, message, false)
	end
end)

EjectRequest.OnServerEvent:Connect(function(player: Player)
	local state = states[player]
	if not state or not passesRateLimit(state, "Eject") then
		return
	end
	eject(player, "You left your host.")
end)

UseAbilityRequest.OnServerEvent:Connect(useAbility)

--------------------------------------------------------------------------------
-- Timers & anti-cheat
--------------------------------------------------------------------------------

local function checkHostSpeed(player: Player, state: PlayerState, root: BasePart, classConfig: NpcClassConfig): boolean
	local clockNow = os.clock()
	local elapsed = clockNow - state.lastSampleTime
	if elapsed < PossessionConfig.AntiCheat.SampleInterval then
		return true
	end

	local previous = state.lastSamplePosition
	local position = root.Position
	state.lastSamplePosition = position
	state.lastSampleTime = clockNow
	if not previous then
		return true
	end

	local delta = position - previous
	local horizontalSpeed = Vector3.new(delta.X, 0, delta.Z).Magnitude / elapsed
	local allowed = classConfig.WalkSpeed * PossessionConfig.AntiCheat.MaxSpeedMultiplier
		+ PossessionConfig.AntiCheat.SpeedSlack

	if horizontalSpeed > allowed then
		state.speedStrikes += 1
		if state.speedStrikes >= PossessionConfig.AntiCheat.StrikesToEject then
			warn(`[PossessionService] {player.Name} host moved at {math.floor(horizontalSpeed)} studs/s; ejecting`)
			return false
		end
	else
		state.speedStrikes = 0
	end
	return true
end

RunService.Heartbeat:Connect(function()
	local now = serverNow()
	for player, state in states do
		local npc = state.npc
		local classConfig = state.classConfig
		if npc and classConfig then
			local root = getRoot(npc)
			if now >= state.expiresAt then
				eject(player, "Your stamina ran out!")
			elseif root and not checkHostSpeed(player, state, root, classConfig) then
				eject(player, "Your host was moving impossibly fast.")
			end
		end
	end
end)
