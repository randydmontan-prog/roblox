--!strict
--[[
	PossessionClient
	================
	Client half of the possession framework.

	  * Puts a ProximityPrompt ([E] / gamepad X / tap) on every GhostNPC and
	    raycasts for line of sight before asking the server to possess.
	  * Drives ghost-form hover flight (Space up, Left Ctrl down).
	  * Smoothly interpolates the camera between bodies with TweenService.
	  * Binds [Q] (class ability), [LeftClick] (melee) and [Space] (eject)
	    while possessing.

	The server is authoritative: everything here is presentation and input.
	Possession state is read from the replicated Player attributes and from
	which model Player.Character currently points at.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PossessionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PossessionConfig"))

type AbilitySlot = PossessionConfig.AbilitySlot

local Tags = PossessionConfig.Tags
local Attributes = PossessionConfig.Attributes

local player = Players.LocalPlayer

local remotes = ReplicatedStorage:WaitForChild(PossessionConfig.Remotes.FolderName)
local PossessRequest = remotes:WaitForChild(PossessionConfig.Remotes.PossessRequest) :: RemoteEvent
local EjectRequest = remotes:WaitForChild(PossessionConfig.Remotes.EjectRequest) :: RemoteEvent
local UseAbilityRequest = remotes:WaitForChild(PossessionConfig.Remotes.UseAbilityRequest) :: RemoteEvent

-- Local-only feedback channel consumed by PossessionUI (lives next to this script).
local localFeedback = Instance.new("BindableEvent")
localFeedback.Name = "BB_LocalFeedback"
localFeedback.Parent = script.Parent

local ACTION_EJECT = "BB_Eject"
local ACTION_ABILITY = "BB_Ability"
local ACTION_MELEE = "BB_Melee"
local ACTION_ASCEND = "BB_GhostAscend"
local ACTION_DESCEND = "BB_GhostDescend"
local CAMERA_BIND = "BB_CameraTransition"
local PROMPT_NAME = "BB_PossessPrompt"
local CLIENT_REQUEST_INTERVAL = 0.25

type Mode = "None" | "Ghost" | "Possessing"

type FlightRig = {
	attachment: Attachment,
	velocity: LinearVelocity,
	orientation: AlignOrientation,
	connection: RBXScriptConnection,
	humanoid: Humanoid,
}

local mode: Mode = "None"
local flightRig: FlightRig? = nil
local cameraTransitionActive = false
local hasSpawnedOnce = false
local ascendHeld = false
local descendHeld = false
local lastPossessRequest = 0
local prompts: { [Model]: ProximityPrompt } = {}

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function notify(message: string, success: boolean)
	localFeedback:Fire(message, success)
end

local function getRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getNumberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return default
end

--------------------------------------------------------------------------------
-- Movement input (PlayerModule controls, with a keyboard fallback)
--------------------------------------------------------------------------------

local controls: any = nil
do
	local playerScripts = player:WaitForChild("PlayerScripts")
	local playerModule = playerScripts:WaitForChild("PlayerModule", 10)
	if playerModule and playerModule:IsA("ModuleScript") then
		local ok, result = pcall(function(): any
			return (require :: any)(playerModule):GetControls()
		end)
		if ok then
			controls = result
		end
	end
end

local function getMoveVector(): Vector3
	if controls then
		local ok, vector = pcall(function(): Vector3
			return controls:GetMoveVector()
		end)
		if ok and typeof(vector) == "Vector3" then
			return vector
		end
	end
	-- Fallback: raw WASD in camera space (forward = -Z).
	local x = 0
	local z = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		z -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		z += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		x -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		x += 1
	end
	local vector = Vector3.new(x, 0, z)
	return if vector.Magnitude > 1 then vector.Unit else vector
end

--------------------------------------------------------------------------------
-- Ghost vision post-processing
--------------------------------------------------------------------------------

local ghostVision = Instance.new("ColorCorrectionEffect")
ghostVision.Name = "BB_GhostVision"
ghostVision.Enabled = true
ghostVision.Parent = Lighting

local visionTween: Tween? = nil

local function setGhostVision(enabled: boolean)
	if visionTween then
		visionTween:Cancel()
	end
	local goal = if enabled
		then { Saturation = -0.45, Contrast = 0.1, Brightness = 0.03, TintColor = Color3.fromRGB(210, 230, 255) }
		else { Saturation = 0, Contrast = 0, Brightness = 0, TintColor = Color3.new(1, 1, 1) }
	local tween = TweenService:Create(
		ghostVision,
		TweenInfo.new(PossessionConfig.Camera.TransitionTime, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		goal
	)
	visionTween = tween
	tween:Play()
end

--------------------------------------------------------------------------------
-- Camera transitions
--------------------------------------------------------------------------------

local function stopCameraTransition()
	if cameraTransitionActive then
		RunService:UnbindFromRenderStep(CAMERA_BIND)
		cameraTransitionActive = false
	end
end

local function getCameraTarget(character: Model): CFrame?
	local head = character:FindFirstChild("Head")
	local focus: BasePart? = if head and head:IsA("BasePart") then head else getRoot(character)
	local root = getRoot(character)
	if not focus or not root then
		return nil
	end
	local look = root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 1e-3 then
		flatLook = Vector3.zAxis
	end
	local eye = focus.Position
		- flatLook.Unit * PossessionConfig.Camera.BackOffset
		+ Vector3.new(0, PossessionConfig.Camera.UpOffset, 0)
	return CFrame.lookAt(eye, focus.Position)
end

--[[
	Eases the camera from wherever it is to an over-the-shoulder view of the
	new body's head. The target is re-evaluated every frame so the camera
	tracks a body that is already moving; easing comes from TweenService.
]]
local function transitionCamera(character: Model, humanoid: Humanoid)
	stopCameraTransition()

	local camera = workspace.CurrentCamera
	local startCFrame = camera.CFrame
	local duration = PossessionConfig.Camera.TransitionTime
	local elapsed = 0

	local function finish()
		stopCameraTransition()
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end

	camera.CameraType = Enum.CameraType.Scriptable
	cameraTransitionActive = true
	RunService:BindToRenderStep(CAMERA_BIND, Enum.RenderPriority.Camera.Value + 1, function(deltaTime: number)
		elapsed += deltaTime
		local target = getCameraTarget(character)
		if not target or not character.Parent then
			finish()
			return
		end
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)
		camera.CFrame = startCFrame:Lerp(target, eased)
		if alpha >= 1 then
			finish()
		end
	end)
end

--------------------------------------------------------------------------------
-- Ghost flight
--------------------------------------------------------------------------------

local function stopFlight()
	local rig = flightRig
	if not rig then
		return
	end
	flightRig = nil
	rig.connection:Disconnect()
	rig.velocity:Destroy()
	rig.orientation:Destroy()
	rig.attachment:Destroy()
	if rig.humanoid.Parent then
		rig.humanoid.PlatformStand = false
	end
end

local function startFlight(character: Model, humanoid: Humanoid)
	stopFlight()
	if not PossessionConfig.Ghost.FlightEnabled then
		return
	end

	local rootInstance = character:WaitForChild("HumanoidRootPart", 10)
	if not rootInstance or not rootInstance:IsA("BasePart") or player.Character ~= character then
		return
	end
	local root: BasePart = rootInstance

	local attachment = Instance.new("Attachment")
	attachment.Name = "BB_FlightAttachment"
	attachment.Parent = root

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "BB_FlightVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.MaxForce = PossessionConfig.Ghost.FlightMaxForce
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = root

	local orientation = Instance.new("AlignOrientation")
	orientation.Name = "BB_FlightOrientation"
	orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orientation.Attachment0 = attachment
	orientation.Responsiveness = PossessionConfig.Ghost.FlightResponsiveness
	orientation.MaxTorque = math.huge
	orientation.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z))
	orientation.Parent = root

	humanoid.PlatformStand = true

	local connection = RunService.Heartbeat:Connect(function()
		local camera = workspace.CurrentCamera
		local cameraCFrame = camera.CFrame
		local move = getMoveVector()

		-- Camera-relative planar movement; looking up/down does not change altitude.
		local flatLook = Vector3.new(cameraCFrame.LookVector.X, 0, cameraCFrame.LookVector.Z)
		local flatRight = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)
		if flatLook.Magnitude > 1e-3 then
			flatLook = flatLook.Unit
		end
		if flatRight.Magnitude > 1e-3 then
			flatRight = flatRight.Unit
		end

		local planar = (flatRight * move.X - flatLook * move.Z) * PossessionConfig.Ghost.FlySpeed
		local vertical = (if ascendHeld then 1 else 0) - (if descendHeld then 1 else 0)
		velocity.VectorVelocity = planar + Vector3.new(0, vertical * PossessionConfig.Ghost.VerticalSpeed, 0)

		local facing = if planar.Magnitude > 0.1 then planar else flatLook
		if facing.Magnitude > 1e-3 then
			orientation.CFrame = CFrame.lookAt(Vector3.zero, facing)
		end
	end)

	flightRig = {
		attachment = attachment,
		velocity = velocity,
		orientation = orientation,
		connection = connection,
		humanoid = humanoid,
	}
end

--------------------------------------------------------------------------------
-- Action bindings
--------------------------------------------------------------------------------

local function requestAbility(slot: AbilitySlot)
	if mode ~= "Possessing" then
		return
	end
	-- Mirror the server cooldown locally to avoid spamming the remote.
	if serverNow() < getNumberAttribute(player, PossessionConfig.AbilityReadyAttribute(slot), 0) then
		return
	end
	UseAbilityRequest:FireServer(slot)
end

local function onEjectAction(_: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin and mode == "Possessing" then
		EjectRequest:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function onAbilityAction(_: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		requestAbility("Primary")
	end
	return Enum.ContextActionResult.Sink
end

local function onMeleeAction(_: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		requestAbility("Melee")
	end
	return Enum.ContextActionResult.Sink
end

local function onAscendAction(_: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	ascendHeld = state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
	return Enum.ContextActionResult.Sink
end

local function onDescendAction(_: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	descendHeld = state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
	return Enum.ContextActionResult.Sink
end

local function unbindAll()
	for _, action in { ACTION_EJECT, ACTION_ABILITY, ACTION_MELEE, ACTION_ASCEND, ACTION_DESCEND } do
		ContextActionService:UnbindAction(action)
	end
	ascendHeld = false
	descendHeld = false
end

local HIGH_PRIORITY = Enum.ContextActionPriority.High.Value

local function bindGhostActions()
	unbindAll()
	if not PossessionConfig.Ghost.FlightEnabled then
		return
	end
	ContextActionService:BindActionAtPriority(
		ACTION_ASCEND,
		onAscendAction,
		true,
		HIGH_PRIORITY,
		Enum.KeyCode.Space,
		Enum.KeyCode.ButtonA
	)
	ContextActionService:BindActionAtPriority(
		ACTION_DESCEND,
		onDescendAction,
		true,
		HIGH_PRIORITY,
		Enum.KeyCode.LeftControl,
		Enum.KeyCode.ButtonB
	)
	ContextActionService:SetTitle(ACTION_ASCEND, "Up")
	ContextActionService:SetTitle(ACTION_DESCEND, "Down")
end

local function bindPossessionActions(classId: string?)
	unbindAll()

	-- Bound above the default jump action so [Space] ejects instead of jumping.
	ContextActionService:BindActionAtPriority(
		ACTION_EJECT,
		onEjectAction,
		true,
		HIGH_PRIORITY,
		Enum.KeyCode.Space,
		Enum.KeyCode.ButtonB
	)
	ContextActionService:SetTitle(ACTION_EJECT, "Eject")

	local classConfig = PossessionConfig.GetClass(classId)
	if not classConfig then
		return
	end

	local primary = PossessionConfig.GetAbility(classConfig, "Primary")
	if primary then
		ContextActionService:BindActionAtPriority(
			ACTION_ABILITY,
			onAbilityAction,
			true,
			HIGH_PRIORITY,
			Enum.KeyCode.Q,
			Enum.KeyCode.ButtonX
		)
		ContextActionService:SetTitle(ACTION_ABILITY, primary.DisplayName)
	end

	local melee = PossessionConfig.GetAbility(classConfig, "Melee")
	if melee then
		ContextActionService:BindActionAtPriority(
			ACTION_MELEE,
			onMeleeAction,
			true,
			HIGH_PRIORITY,
			Enum.UserInputType.MouseButton1,
			Enum.KeyCode.ButtonR2
		)
		ContextActionService:SetTitle(ACTION_MELEE, melee.DisplayName)
	end
end

--------------------------------------------------------------------------------
-- Possession prompts
--------------------------------------------------------------------------------

local function hasLineOfSight(fromModel: Model, toModel: Model, from: Vector3, to: Vector3): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { fromModel, toModel }
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return workspace:Raycast(from, to - from, params) == nil
end

local function requestPossess(npc: Model)
	if mode ~= "Ghost" then
		return
	end
	local now = os.clock()
	if now - lastPossessRequest < CLIENT_REQUEST_INTERVAL then
		return
	end

	local readyAt = getNumberAttribute(player, Attributes.RepossessReadyAt, 0)
	if serverNow() < readyAt then
		notify(string.format("Your spirit is recovering (%.1fs).", readyAt - serverNow()), false)
		return
	end

	local ghost = player.Character
	local ghostRoot = if ghost then getRoot(ghost) else nil
	local npcRoot = getRoot(npc)
	if not ghost or not ghostRoot or not npcRoot then
		return
	end
	if (ghostRoot.Position - npcRoot.Position).Magnitude >= PossessionConfig.Possession.MaxDistance then
		notify("Too far away to possess.", false)
		return
	end
	if not hasLineOfSight(ghost, npc, ghostRoot.Position, npcRoot.Position) then
		notify("Something is blocking your way.", false)
		return
	end

	lastPossessRequest = now
	PossessRequest:FireServer(npc)
end

local function removePrompt(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local prompt = prompts[instance]
	if prompt then
		prompts[instance] = nil
		prompt:Destroy()
	end
end

local function addPrompt(instance: Instance)
	if not instance:IsA("Model") or prompts[instance] then
		return
	end
	local npc: Model = instance
	local rootInstance = npc:FindFirstChild("HumanoidRootPart") or npc:WaitForChild("HumanoidRootPart", 10)
	if not rootInstance or not rootInstance:IsA("BasePart") or prompts[npc] or not CollectionService:HasTag(npc, Tags.GhostNPC) then
		return
	end

	local classConfig = PossessionConfig.GetClass(npc:GetAttribute(Attributes.NPCClass))

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Possess"
	prompt.ObjectText = if classConfig then classConfig.DisplayName else npc.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PossessionConfig.Possession.ClientPromptDistance
	-- Line of sight is checked against the whole body in requestPossess instead.
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
	prompt.Enabled = false
	prompt.Triggered:Connect(function()
		requestPossess(npc)
	end)
	prompt.Parent = rootInstance

	prompts[npc] = prompt
end

local function refreshPrompts()
	local canPossess = mode == "Ghost" and serverNow() >= getNumberAttribute(player, Attributes.RepossessReadyAt, 0)
	for npc, prompt in prompts do
		if not npc.Parent then
			removePrompt(npc)
			continue
		end
		local humanoid = npc:FindFirstChildOfClass("Humanoid")
		prompt.Enabled = canPossess
			and humanoid ~= nil
			and humanoid.Health > 0
			and npc:GetAttribute(Attributes.PossessedBy) == nil
	end
end

for _, instance in CollectionService:GetTagged(Tags.GhostNPC) do
	task.spawn(addPrompt, instance)
end
CollectionService:GetInstanceAddedSignal(Tags.GhostNPC):Connect(addPrompt)
CollectionService:GetInstanceRemovedSignal(Tags.GhostNPC):Connect(removePrompt)

local promptAccumulator = 0
RunService.Heartbeat:Connect(function(deltaTime: number)
	promptAccumulator += deltaTime
	if promptAccumulator >= 0.1 then
		promptAccumulator = 0
		refreshPrompts()
	end
end)

--------------------------------------------------------------------------------
-- Character lifecycle
--------------------------------------------------------------------------------

local function onCharacterAdded(character: Model)
	stopFlight()

	local humanoidInstance = character:WaitForChild("Humanoid", 10)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") or player.Character ~= character then
		return
	end
	local humanoid: Humanoid = humanoidInstance

	local isFirstSpawn = not hasSpawnedOnce
	hasSpawnedOnce = true

	if CollectionService:HasTag(character, Tags.GhostNPC) then
		mode = "Possessing"
		local classId = character:GetAttribute(Attributes.NPCClass)
		bindPossessionActions(if type(classId) == "string" then classId else nil)
		setGhostVision(false)
		transitionCamera(character, humanoid)
	else
		mode = "Ghost"
		bindGhostActions()
		setGhostVision(true)
		if isFirstSpawn then
			local camera = workspace.CurrentCamera
			camera.CameraType = Enum.CameraType.Custom
			camera.CameraSubject = humanoid
		else
			transitionCamera(character, humanoid)
		end
		startFlight(character, humanoid)
	end

	refreshPrompts()
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end
