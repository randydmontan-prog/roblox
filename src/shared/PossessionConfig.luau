--!strict
--[[
	PossessionConfig
	================
	Single source of truth for all "Borrowed Body" possession tuning. Shared by
	server and client so that both sides agree on distances, durations,
	cooldowns, tag names, remote names and attribute keys.

	Everything in here is deep-frozen at require time; treat it as read-only.
]]

export type AbilitySlot = "Primary" | "Melee"
export type AbilityEffect = "Keycard" | "Repair" | "Melee"

export type AbilityConfig = {
	Id: string,
	DisplayName: string,
	Description: string,
	Effect: AbilityEffect,
	-- Label shown on the HUD for the bound input (e.g. "Q", "LMB").
	InputLabel: string,
	-- Glyph rendered inside the HUD ability slot.
	Icon: string,
	-- Seconds before the ability can be used again after a successful use.
	Cooldown: number,
	-- Studs from the host's HumanoidRootPart that the ability can reach.
	Range: number,
	-- Seconds of possession stamina consumed per successful use.
	StaminaCost: number,
	-- Effect-specific tuning. Unused values are left at 0.
	Damage: number,
	MaxTargets: number,
	RepairAmount: number,
}

export type NpcClassConfig = {
	Id: string,
	DisplayName: string,
	-- Seconds of possession granted by this host (the stamina pool).
	Duration: number,
	-- WalkSpeed while possessed.
	WalkSpeed: number,
	-- WalkSpeed while idle / unpossessed.
	IdleWalkSpeed: number,
	JumpHeight: number,
	MaxHealth: number,
	AccentColor: Color3,
	SecondaryColor: Color3,
	Abilities: { [AbilitySlot]: AbilityConfig },
}

local DEFAULT_POSSESSION_DURATION = 20

local Classes: { [string]: NpcClassConfig } = {
	SecurityGuard = {
		Id = "SecurityGuard",
		DisplayName = "Security Guard",
		Duration = DEFAULT_POSSESSION_DURATION,
		WalkSpeed = 16,
		IdleWalkSpeed = 8,
		JumpHeight = 7.2,
		MaxHealth = 100,
		AccentColor = Color3.fromRGB(52, 94, 168),
		SecondaryColor = Color3.fromRGB(28, 36, 56),
		Abilities = {
			Primary = {
				Id = "KeycardSwipe",
				DisplayName = "Keycard Swipe",
				Description = "Opens the nearest Security Door.",
				Effect = "Keycard",
				InputLabel = "Q",
				Icon = "🔑",
				Cooldown = 2,
				Range = 12,
				StaminaCost = 0,
				Damage = 0,
				MaxTargets = 0,
				RepairAmount = 0,
			},
		},
	},

	Mechanic = {
		Id = "Mechanic",
		DisplayName = "Mechanic",
		Duration = DEFAULT_POSSESSION_DURATION,
		WalkSpeed = 15,
		IdleWalkSpeed = 8,
		JumpHeight = 7.2,
		MaxHealth = 100,
		AccentColor = Color3.fromRGB(214, 138, 38),
		SecondaryColor = Color3.fromRGB(70, 58, 44),
		Abilities = {
			Primary = {
				Id = "Repair",
				DisplayName = "Repair",
				Description = "Repairs the nearest Broken Generator.",
				Effect = "Repair",
				InputLabel = "Q",
				Icon = "🔧",
				Cooldown = 1.25,
				Range = 10,
				StaminaCost = 1,
				Damage = 0,
				MaxTargets = 0,
				RepairAmount = 34,
			},
		},
	},

	Brawler = {
		Id = "Brawler",
		DisplayName = "Brawler",
		Duration = 18,
		WalkSpeed = 18,
		IdleWalkSpeed = 9,
		JumpHeight = 8,
		MaxHealth = 250,
		AccentColor = Color3.fromRGB(176, 42, 42),
		SecondaryColor = Color3.fromRGB(40, 30, 30),
		Abilities = {
			Melee = {
				Id = "Punch",
				DisplayName = "Punch",
				Description = "Strikes everything directly in front of you.",
				Effect = "Melee",
				InputLabel = "LMB",
				Icon = "👊",
				Cooldown = 0.6,
				Range = 6,
				StaminaCost = 0,
				Damage = 25,
				MaxTargets = 3,
				RepairAmount = 0,
			},
		},
	},
}

-- Order abilities appear in on the HUD.
local AbilitySlots: { AbilitySlot } = { "Primary", "Melee" }

local PossessionConfig = {
	Tags = {
		GhostNPC = "GhostNPC",
		SecurityDoor = "SecurityDoor",
		BrokenGenerator = "BrokenGenerator",
		-- Applied once a BrokenGenerator is fully repaired (the BrokenGenerator tag is removed).
		RepairedGenerator = "RepairedGenerator",
	},

	Remotes = {
		FolderName = "PossessionRemotes",
		-- Client -> Server
		PossessRequest = "PossessRequest",
		EjectRequest = "EjectRequest",
		UseAbilityRequest = "UseAbilityRequest",
		-- Server -> Client: (message: string, success: boolean)
		Feedback = "PossessionFeedback",
	},

	Attributes = {
		-- Replicated on the Player (authoritative possession state for the HUD).
		Possessing = "BB_Possessing",
		ClassId = "BB_ClassId",
		Duration = "BB_PossessDuration",
		ExpiresAt = "BB_PossessExpiresAt",
		RepossessReadyAt = "BB_RepossessReadyAt",
		AbilityReadyPrefix = "BB_AbilityReady_",

		-- Characters / NPC models.
		IsGhost = "BB_IsGhost",
		NPCClass = "NPCClass",
		PossessedBy = "BB_PossessedBy",

		-- Interactables.
		DoorOpen = "BB_DoorOpen",
		RepairProgress = "BB_RepairProgress",
		Repaired = "BB_Repaired",
	},

	CollisionGroups = {
		Ghost = "BB_Ghost",
		NPC = "BB_NPC",
	},

	Possession = {
		-- Server-authoritative maximum distance (studs) between ghost and NPC roots.
		MaxDistance = 15,
		-- Prompt activation distance on the client; slightly under MaxDistance to absorb latency.
		ClientPromptDistance = 13.5,
		DefaultDuration = DEFAULT_POSSESSION_DURATION,
		-- Seconds after ejecting before the player may possess again.
		RepossessCooldown = 3,
		-- Studs above the host's root where the ghost reappears on ejection.
		EjectHeightOffset = 4,
		-- Minimum seconds between two requests of the same kind from one player.
		RequestMinInterval = 0.15,
	},

	AntiCheat = {
		-- Horizontal host speed allowed = WalkSpeed * multiplier + slack.
		MaxSpeedMultiplier = 2.5,
		SpeedSlack = 12,
		SampleInterval = 0.5,
		-- Consecutive violating samples before the player is forcibly ejected.
		StrikesToEject = 3,
	},

	Ghost = {
		WalkSpeed = 28,
		FlightEnabled = true,
		FlySpeed = 34,
		VerticalSpeed = 24,
		FlightMaxForce = 400000,
		FlightResponsiveness = 25,
		Transparency = 0.6,
		Tint = Color3.fromRGB(150, 210, 255),
		RespawnDelay = 2,
	},

	Door = {
		PanelName = "Panel",
		StatusLightName = "StatusLight",
		OpenDuration = 5,
		TweenTime = 0.6,
		LockedColor = Color3.fromRGB(220, 50, 50),
		OpenColor = Color3.fromRGB(60, 220, 90),
	},

	Generator = {
		CoreName = "Core",
		BrokenColor = Color3.fromRGB(200, 40, 30),
		RepairedColor = Color3.fromRGB(70, 255, 120),
	},

	Camera = {
		TransitionTime = 0.65,
		BackOffset = 10,
		UpOffset = 2.5,
	},

	TestEnvironment = {
		Enabled = true,
		SpawnBrawler = true,
		SpawnTrainingDummy = true,
		NpcRespawnDelay = 6,
	},

	AbilitySlots = AbilitySlots,
	Classes = Classes,
}

local function deepFreeze(value: any): any
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child in value do
			deepFreeze(child)
		end
		table.freeze(value)
	end
	return value
end

deepFreeze(PossessionConfig)

local Module = {}

Module.Config = PossessionConfig

-- Re-export config tables at the top level for ergonomic access (Config.Tags.GhostNPC).
Module.Tags = PossessionConfig.Tags
Module.Remotes = PossessionConfig.Remotes
Module.Attributes = PossessionConfig.Attributes
Module.CollisionGroups = PossessionConfig.CollisionGroups
Module.Possession = PossessionConfig.Possession
Module.AntiCheat = PossessionConfig.AntiCheat
Module.Ghost = PossessionConfig.Ghost
Module.Door = PossessionConfig.Door
Module.Generator = PossessionConfig.Generator
Module.Camera = PossessionConfig.Camera
Module.TestEnvironment = PossessionConfig.TestEnvironment
Module.AbilitySlots = PossessionConfig.AbilitySlots
Module.Classes = PossessionConfig.Classes

--[[
	Returns the class config for an NPCClass attribute value, or nil when the
	value is missing or unknown. Accepts `unknown` so callers can pass raw
	attribute values straight through.
]]
function Module.GetClass(classId: unknown): NpcClassConfig?
	if type(classId) ~= "string" then
		return nil
	end
	return Classes[classId]
end

--[[
	Returns the ability bound to `slot` for the given class, if any.
]]
function Module.GetAbility(classConfig: NpcClassConfig, slot: AbilitySlot): AbilityConfig?
	-- Indexers type as non-optional, but a class may not define every slot.
	local ability: AbilityConfig? = classConfig.Abilities[slot]
	return ability
end

--[[
	Validates an untrusted value (e.g. from a RemoteEvent) as an AbilitySlot.
]]
function Module.ToAbilitySlot(value: unknown): AbilitySlot?
	if value == "Primary" then
		return "Primary"
	elseif value == "Melee" then
		return "Melee"
	end
	return nil
end

--[[
	Player attribute holding the server time at which `slot` comes off cooldown.
]]
function Module.AbilityReadyAttribute(slot: AbilitySlot): string
	return PossessionConfig.Attributes.AbilityReadyPrefix .. slot
end

return table.freeze(Module)
