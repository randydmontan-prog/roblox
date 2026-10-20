# Borrowed Body

Possession-based gameplay framework for Roblox, built for Rojo.

| File | Becomes in Studio |
| --- | --- |
| `src/shared/PossessionConfig.luau` | `ReplicatedStorage.Shared.PossessionConfig` (ModuleScript) |
| `src/server/PossessionService.server.luau` | `ServerScriptService.Server.PossessionService` (Script) |
| `src/server/TestSetup.server.luau` | `ServerScriptService.Server.TestSetup` (Script) |
| `src/client/PossessionClient.client.luau` | `StarterPlayer.StarterPlayerScripts.Client.PossessionClient` (LocalScript) |
| `src/client/PossessionUI.client.luau` | `StarterPlayer.StarterPlayerScripts.Client.PossessionUI` (LocalScript) |

## Running in Studio

1. Install the Rojo CLI (`rokit install`, or download Rojo 7.4+), and the Rojo Studio plugin.
2. In this folder run `rojo serve`.
3. In Studio open a Baseplate place, open the Rojo plugin, click **Connect**.
4. Press **Play**. TestSetup builds the test area automatically.

## Controls

| Form | Input | Action |
| --- | --- | --- |
| Ghost | E (prompt) | Possess a body within 15 studs |
| Ghost | Space / Left Ctrl | Rise / sink |
| Possessed | Q | Class ability (Guard: open door, Mechanic: repair) |
| Possessed | Left click | Brawler punch |
| Possessed | Space | Eject (3 s re-possession cooldown) |

Turn the sandbox off with `TestEnvironment.Enabled = false` in `PossessionConfig`.
