--!strict
--[[
	PossessionUI
	============
	Builds and drives the possession HUD:

	  * Possession panel: host class label, stamina/timer bar, eject hint and
	    one slot per class ability (icon, input key, cooldown sweep).
	  * Ghost panel: ghost-form hints and the re-possession cooldown.
	  * Toasts for server feedback and local feedback from PossessionClient.

	All timing is derived from replicated Player attributes written by
	PossessionService, compared against workspace:GetServerTimeNow().
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local PossessionConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PossessionConfig"))

type AbilityConfig = PossessionConfig.AbilityConfig
type AbilitySlot = PossessionConfig.AbilitySlot
type NpcClassConfig = PossessionConfig.NpcClassConfig

local Attributes = PossessionConfig.Attributes

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild(PossessionConfig.Remotes.FolderName)
local FeedbackRemote = remotes:WaitForChild(PossessionConfig.Remotes.Feedback) :: RemoteEvent

local COLORS = {
	Panel = Color3.fromRGB(16, 18, 26),
	PanelStroke = Color3.fromRGB(90, 110, 150),
	Text = Color3.fromRGB(235, 240, 250),
	SubText = Color3.fromRGB(160, 172, 196),
	BarBackground = Color3.fromRGB(38, 42, 56),
	StaminaHigh = Color3.fromRGB(80, 220, 120),
	StaminaMid = Color3.fromRGB(240, 200, 60),
	StaminaLow = Color3.fromRGB(235, 70, 60),
	Ghost = PossessionConfig.Ghost.Tint,
	Success = Color3.fromRGB(110, 230, 140),
	Failure = Color3.fromRGB(255, 120, 110),
}

local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold
local TOAST_DURATION = 2.25
local LOW_STAMINA_FRACTION = 0.25

type AbilitySlotUI = {
	slot: AbilitySlot,
	ability: AbilityConfig,
	frame: Frame,
	cooldownOverlay: Frame,
	cooldownText: TextLabel,
}

--------------------------------------------------------------------------------
-- Construction helpers
--------------------------------------------------------------------------------

local function corner(parent: GuiObject, radius: number)
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0, radius)
	uiCorner.Parent = parent
end

local function stroke(parent: GuiObject, color: Color3, transparency: number)
	local uiStroke = Instance.new("UIStroke")
	uiStroke.Color = color
	uiStroke.Transparency = transparency
	uiStroke.Thickness = 1.5
	uiStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	uiStroke.Parent = parent
end

local function label(
	name: string,
	parent: Instance,
	text: string,
	size: UDim2,
	position: UDim2,
	textSize: number,
	font: Enum.Font,
	color: Color3,
	alignment: Enum.TextXAlignment
): TextLabel
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = name
	textLabel.BackgroundTransparency = 1
	textLabel.Size = size
	textLabel.Position = position
	textLabel.Text = text
	textLabel.TextSize = textSize
	textLabel.Font = font
	textLabel.TextColor3 = color
	textLabel.TextXAlignment = alignment
	textLabel.TextYAlignment = Enum.TextYAlignment.Center
	textLabel.TextTruncate = Enum.TextTruncate.AtEnd
	textLabel.Parent = parent
	return textLabel
end

local function getNumberAttribute(name: string, default: number): number
	local value = player:GetAttribute(name)
	if type(value) == "number" then
		return value
	end
	return default
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local existing = playerGui:FindFirstChild("BB_PossessionUI")
if existing then
	existing:Destroy()
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "BB_PossessionUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 10

local uiScale = Instance.new("UIScale")
uiScale.Parent = screenGui

local root = Instance.new("Frame")
root.Name = "Root"
root.AnchorPoint = Vector2.new(0.5, 1)
root.Position = UDim2.new(0.5, 0, 1, -24)
root.Size = UDim2.fromOffset(440, 132)
root.BackgroundTransparency = 1
root.Parent = screenGui

-- Toast ------------------------------------------------------------------------

local toast = label(
	"Toast",
	root,
	"",
	UDim2.new(1, 0, 0, 28),
	UDim2.new(0, 0, 0, -36),
	18,
	FONT_BOLD,
	COLORS.Text,
	Enum.TextXAlignment.Center
)
toast.TextTransparency = 1
toast.TextStrokeTransparency = 1
toast.TextStrokeColor3 = Color3.new(0, 0, 0)

-- Possession panel -------------------------------------------------------------

local possessionPanel = Instance.new("Frame")
possessionPanel.Name = "PossessionPanel"
possessionPanel.Size = UDim2.fromScale(1, 1)
possessionPanel.BackgroundColor3 = COLORS.Panel
possessionPanel.BackgroundTransparency = 0.15
possessionPanel.Visible = false
possessionPanel.Parent = root
corner(possessionPanel, 12)
stroke(possessionPanel, COLORS.PanelStroke, 0.4)

local panelPadding = Instance.new("UIPadding")
panelPadding.PaddingTop = UDim.new(0, 10)
panelPadding.PaddingBottom = UDim.new(0, 10)
panelPadding.PaddingLeft = UDim.new(0, 14)
panelPadding.PaddingRight = UDim.new(0, 14)
panelPadding.Parent = possessionPanel

local accentBar = Instance.new("Frame")
accentBar.Name = "Accent"
accentBar.Size = UDim2.new(0, 4, 0, 22)
accentBar.Position = UDim2.fromOffset(0, 1)
accentBar.BorderSizePixel = 0
accentBar.Parent = possessionPanel
corner(accentBar, 2)

local classLabel = label(
	"ClassLabel",
	possessionPanel,
	"",
	UDim2.new(0.6, -12, 0, 24),
	UDim2.fromOffset(12, 0),
	20,
	FONT_BOLD,
	COLORS.Text,
	Enum.TextXAlignment.Left
)

label(
	"EjectHint",
	possessionPanel,
	"[Space] Eject",
	UDim2.new(0.4, 0, 0, 24),
	UDim2.fromScale(0.6, 0),
	14,
	FONT,
	COLORS.SubText,
	Enum.TextXAlignment.Right
)

local staminaBackground = Instance.new("Frame")
staminaBackground.Name = "StaminaBar"
staminaBackground.Size = UDim2.new(1, -64, 0, 14)
staminaBackground.Position = UDim2.fromOffset(0, 32)
staminaBackground.BackgroundColor3 = COLORS.BarBackground
staminaBackground.BorderSizePixel = 0
staminaBackground.ClipsDescendants = true
staminaBackground.Parent = possessionPanel
corner(staminaBackground, 7)

local staminaFill = Instance.new("Frame")
staminaFill.Name = "Fill"
staminaFill.Size = UDim2.fromScale(1, 1)
staminaFill.BackgroundColor3 = COLORS.StaminaHigh
staminaFill.BorderSizePixel = 0
staminaFill.Parent = staminaBackground
corner(staminaFill, 7)

local staminaGradient = Instance.new("UIGradient")
staminaGradient.Rotation = 90
staminaGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(1, 0.35),
})
staminaGradient.Parent = staminaFill

local staminaText = label(
	"StaminaText",
	possessionPanel,
	"",
	UDim2.fromOffset(56, 18),
	UDim2.new(1, -56, 0, 30),
	16,
	FONT_BOLD,
	COLORS.Text,
	Enum.TextXAlignment.Right
)

local abilityRow = Instance.new("Frame")
abilityRow.Name = "Abilities"
abilityRow.BackgroundTransparency = 1
abilityRow.Size = UDim2.new(1, 0, 0, 56)
abilityRow.Position = UDim2.fromOffset(0, 56)
abilityRow.Parent = possessionPanel

local abilityLayout = Instance.new("UIListLayout")
abilityLayout.FillDirection = Enum.FillDirection.Horizontal
abilityLayout.Padding = UDim.new(0, 10)
abilityLayout.SortOrder = Enum.SortOrder.LayoutOrder
abilityLayout.VerticalAlignment = Enum.VerticalAlignment.Center
abilityLayout.Parent = abilityRow

-- Ghost panel ------------------------------------------------------------------

local ghostPanel = Instance.new("Frame")
ghostPanel.Name = "GhostPanel"
ghostPanel.AnchorPoint = Vector2.new(0.5, 1)
ghostPanel.Position = UDim2.fromScale(0.5, 1)
ghostPanel.Size = UDim2.new(1, 0, 0, 74)
ghostPanel.BackgroundColor3 = COLORS.Panel
ghostPanel.BackgroundTransparency = 0.3
ghostPanel.Visible = false
ghostPanel.Parent = root
corner(ghostPanel, 12)
stroke(ghostPanel, COLORS.Ghost, 0.35)

label(
	"Title",
	ghostPanel,
	"👻  GHOST FORM",
	UDim2.new(1, -28, 0, 26),
	UDim2.fromOffset(14, 8),
	20,
	FONT_BOLD,
	COLORS.Ghost,
	Enum.TextXAlignment.Left
)

local ghostHint = label(
	"Hint",
	ghostPanel,
	"",
	UDim2.new(1, -28, 0, 20),
	UDim2.fromOffset(14, 38),
	14,
	FONT,
	COLORS.SubText,
	Enum.TextXAlignment.Left
)

local cooldownBackground = Instance.new("Frame")
cooldownBackground.Name = "RepossessCooldown"
cooldownBackground.Size = UDim2.new(1, -28, 0, 4)
cooldownBackground.Position = UDim2.new(0, 14, 1, -10)
cooldownBackground.BackgroundColor3 = COLORS.BarBackground
cooldownBackground.BorderSizePixel = 0
cooldownBackground.Visible = false
cooldownBackground.Parent = ghostPanel
corner(cooldownBackground, 2)

local cooldownFill = Instance.new("Frame")
cooldownFill.Name = "Fill"
cooldownFill.Size = UDim2.fromScale(0, 1)
cooldownFill.BackgroundColor3 = COLORS.Ghost
cooldownFill.BorderSizePixel = 0
cooldownFill.Parent = cooldownBackground
corner(cooldownFill, 2)

screenGui.Parent = playerGui

--------------------------------------------------------------------------------
-- Ability slots
--------------------------------------------------------------------------------

local abilitySlots: { AbilitySlotUI } = {}
local currentClassId: string? = nil

local function clearAbilitySlots()
	for _, slotUI in abilitySlots do
		slotUI.frame:Destroy()
	end
	table.clear(abilitySlots)
end

local function createAbilitySlot(slot: AbilitySlot, ability: AbilityConfig, order: number, accent: Color3): AbilitySlotUI
	local frame = Instance.new("Frame")
	frame.Name = ability.Id
	frame.LayoutOrder = order
	frame.Size = UDim2.fromOffset(190, 52)
	frame.BackgroundColor3 = COLORS.BarBackground
	frame.BackgroundTransparency = 0.2
	frame.Parent = abilityRow
	corner(frame, 10)
	stroke(frame, accent, 0.45)

	local iconFrame = Instance.new("Frame")
	iconFrame.Name = "Icon"
	iconFrame.Size = UDim2.fromOffset(44, 44)
	iconFrame.Position = UDim2.fromOffset(4, 4)
	iconFrame.BackgroundColor3 = accent
	iconFrame.BackgroundTransparency = 0.35
	iconFrame.ClipsDescendants = true
	iconFrame.Parent = frame
	corner(iconFrame, 8)

	label("Glyph", iconFrame, ability.Icon, UDim2.fromScale(1, 1), UDim2.new(), 26, FONT, COLORS.Text, Enum.TextXAlignment.Center)

	-- Fills from the top and shrinks downward as the cooldown elapses.
	local cooldownOverlay = Instance.new("Frame")
	cooldownOverlay.Name = "Cooldown"
	cooldownOverlay.AnchorPoint = Vector2.new(0, 1)
	cooldownOverlay.Position = UDim2.fromScale(0, 1)
	cooldownOverlay.Size = UDim2.fromScale(1, 0)
	cooldownOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	cooldownOverlay.BackgroundTransparency = 0.35
	cooldownOverlay.BorderSizePixel = 0
	cooldownOverlay.ZIndex = 2
	cooldownOverlay.Parent = iconFrame

	local cooldownText = label(
		"CooldownText",
		iconFrame,
		"",
		UDim2.fromScale(1, 1),
		UDim2.new(),
		16,
		FONT_BOLD,
		COLORS.Text,
		Enum.TextXAlignment.Center
	)
	cooldownText.ZIndex = 3

	label(
		"Name",
		frame,
		ability.DisplayName,
		UDim2.new(1, -60, 0, 20),
		UDim2.fromOffset(56, 6),
		15,
		FONT_BOLD,
		COLORS.Text,
		Enum.TextXAlignment.Left
	)

	local keyBadge = Instance.new("TextLabel")
	keyBadge.Name = "Key"
	keyBadge.Size = UDim2.fromOffset(40, 18)
	keyBadge.Position = UDim2.fromOffset(56, 28)
	keyBadge.BackgroundColor3 = COLORS.Panel
	keyBadge.Text = `[{ability.InputLabel}]`
	keyBadge.TextSize = 12
	keyBadge.Font = FONT_BOLD
	keyBadge.TextColor3 = COLORS.SubText
	keyBadge.Parent = frame
	corner(keyBadge, 4)

	label(
		"Cooldown",
		frame,
		string.format("%.1fs", ability.Cooldown),
		UDim2.new(1, -104, 0, 18),
		UDim2.fromOffset(100, 28),
		12,
		FONT,
		COLORS.SubText,
		Enum.TextXAlignment.Left
	)

	return {
		slot = slot,
		ability = ability,
		frame = frame,
		cooldownOverlay = cooldownOverlay,
		cooldownText = cooldownText,
	}
end

local function rebuildForClass(classConfig: NpcClassConfig?)
	local newId = if classConfig then classConfig.Id else nil
	if newId == currentClassId then
		return
	end
	currentClassId = newId
	clearAbilitySlots()

	if not classConfig then
		return
	end

	classLabel.Text = string.upper(classConfig.DisplayName)
	accentBar.BackgroundColor3 = classConfig.AccentColor

	for index, slot: AbilitySlot in PossessionConfig.AbilitySlots do
		local ability = PossessionConfig.GetAbility(classConfig, slot)
		if ability then
			table.insert(abilitySlots, createAbilitySlot(slot, ability, index, classConfig.AccentColor))
		end
	end
end

--------------------------------------------------------------------------------
-- Toasts
--------------------------------------------------------------------------------

local toastToken = 0
local TOAST_FADE = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function showToast(message: string, success: boolean)
	if message == "" then
		return
	end
	toastToken += 1
	local token = toastToken

	toast.Text = message
	toast.TextColor3 = if success then COLORS.Success else COLORS.Failure
	TweenService:Create(toast, TOAST_FADE, { TextTransparency = 0, TextStrokeTransparency = 0.4 }):Play()

	task.delay(TOAST_DURATION, function()
		if token == toastToken then
			TweenService:Create(toast, TOAST_FADE, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

FeedbackRemote.OnClientEvent:Connect(function(message: unknown, success: unknown)
	if type(message) == "string" then
		showToast(message, success == true)
	end
end)

task.spawn(function()
	local localFeedback = script.Parent:WaitForChild("BB_LocalFeedback", 30)
	if localFeedback and localFeedback:IsA("BindableEvent") then
		localFeedback.Event:Connect(function(message: unknown, success: unknown)
			if type(message) == "string" then
				showToast(message, success == true)
			end
		end)
	end
end)

--------------------------------------------------------------------------------
-- Per-frame update
--------------------------------------------------------------------------------

local function staminaColor(fraction: number): Color3
	if fraction > 0.5 then
		return COLORS.StaminaMid:Lerp(COLORS.StaminaHigh, (fraction - 0.5) * 2)
	end
	return COLORS.StaminaLow:Lerp(COLORS.StaminaMid, fraction * 2)
end

local function updateScale()
	local viewport = workspace.CurrentCamera.ViewportSize
	uiScale.Scale = math.clamp(math.min(viewport.X / 900, viewport.Y / 600), 0.6, 1.15)
end

local function updatePossessionPanel(now: number)
	local classConfig = PossessionConfig.GetClass(player:GetAttribute(Attributes.ClassId))
	rebuildForClass(classConfig)

	local duration = math.max(getNumberAttribute(Attributes.Duration, PossessionConfig.Possession.DefaultDuration), 0.001)
	local remaining = math.max(getNumberAttribute(Attributes.ExpiresAt, now) - now, 0)
	local fraction = math.clamp(remaining / duration, 0, 1)

	staminaFill.Size = UDim2.fromScale(fraction, 1)
	local color = staminaColor(fraction)
	if fraction <= LOW_STAMINA_FRACTION then
		-- Pulse while low on stamina.
		local pulse = (math.sin(os.clock() * 10) + 1) / 2
		color = color:Lerp(Color3.new(1, 1, 1), pulse * 0.35)
	end
	staminaFill.BackgroundColor3 = color
	staminaText.Text = string.format("%.1fs", remaining)
	staminaText.TextColor3 = if fraction <= LOW_STAMINA_FRACTION then COLORS.StaminaLow else COLORS.Text

	for _, slotUI in abilitySlots do
		local readyAt = getNumberAttribute(PossessionConfig.AbilityReadyAttribute(slotUI.slot), 0)
		local cooldownRemaining = math.max(readyAt - now, 0)
		local cooldownFraction = if slotUI.ability.Cooldown > 0
			then math.clamp(cooldownRemaining / slotUI.ability.Cooldown, 0, 1)
			else 0
		slotUI.cooldownOverlay.Size = UDim2.fromScale(1, cooldownFraction)
		slotUI.cooldownText.Text = if cooldownRemaining > 0 then string.format("%.1f", cooldownRemaining) else ""
	end
end

local function updateGhostPanel(now: number)
	local readyAt = getNumberAttribute(Attributes.RepossessReadyAt, 0)
	local remaining = math.max(readyAt - now, 0)
	if remaining > 0 then
		ghostHint.Text = string.format("Your spirit is recovering... %.1fs", remaining)
		cooldownBackground.Visible = true
		local cooldown = math.max(PossessionConfig.Possession.RepossessCooldown, 0.001)
		cooldownFill.Size = UDim2.fromScale(1 - math.clamp(remaining / cooldown, 0, 1), 1)
	else
		local hint = "[E] Possess a nearby body"
		if PossessionConfig.Ghost.FlightEnabled then
			hint ..= "   ·   [Space] Rise   ·   [Ctrl] Sink"
		end
		ghostHint.Text = hint
		cooldownBackground.Visible = false
	end
end

RunService.RenderStepped:Connect(function()
	updateScale()
	local now = workspace:GetServerTimeNow()
	local possessing = player:GetAttribute(Attributes.Possessing) == true

	possessionPanel.Visible = possessing
	ghostPanel.Visible = not possessing and player.Character ~= nil

	if possessing then
		updatePossessionPanel(now)
	else
		rebuildForClass(nil)
		updateGhostPanel(now)
	end
end)
