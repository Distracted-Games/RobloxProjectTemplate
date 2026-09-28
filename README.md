# Roblox Project Template

A professional, modern Roblox project template engineered for production games. Pre-configured for **Roblox Script Sync**, **Luau Language Server**, **Selene**, and **Stylua**, this template provides a clean development environment and a comprehensive, production-ready architecture covering state replication, modal UI navigation, modern audio, and action-based inputs.

---

## 📑 Table of Contents

- [Getting Started](#getting-started)
	- [Option 1: Create a New Repository from This Template](#option-1-create-a-new-repository-from-this-template)
	- [Option 2: Clone This Repository Directly](#option-2-clone-this-repository-directly)
	- [Option 3: Using VS Code Source Control UI](#option-3-using-vs-code-source-control-ui)
- [Architecture & Primary Systems](#architecture--primary-systems)
	- [ModuleLoader](#moduleloader)
	- [Data Stack (PlayerDataService & DataController)](#data-stack-playerdataservice--datacontroller)
	- [UI Management (MVC Architecture)](#ui-management-mvc-architecture)
	- [InputController](#inputcontroller)
	- [AudioController](#audiocontroller)
	- [SafeTeleport](#safeteleport)
- [Prevalent Libraries & Utilities](#prevalent-libraries--utilities)
	- [Open-Source Libraries](#open-source-libraries)
	- [Built-In Utilities](#built-in-utilities)
- [Development Tools & Setup](#development-tools--setup)
	- [Roblox Script Sync & Luau LSP](#roblox-script-sync--luau-lsp)
	- [Static Analysis & Code Formatting](#static-analysis--code-formatting)
	- [Roblox Server Authority Ready](#roblox-server-authority-ready)
- [VS Code Workspace Configuration](#vs-code-workspace-configuration)
	- [Recommended Extensions](#recommended-extensions)

---

## Getting Started

You have three convenient ways to start using this template for your own Roblox project:

### Option 1: Create a New Repository from This Template

Using GitHub's template feature is recommended for a fresh start, as it initializes your project without carrying over the template's past commit history.

1. **Use the Template**
	- Click the green **"Use this template"** button at the top of the [GitHub repo](https://github.com/Distracted-Games/RobloxProjectTemplate).
	- Select **"Create a new repository"** and fill in your desired repository name and settings.
	- Click the green **"<> Code"** button and copy your new repository URL.
2. **Navigate to Your Local Parent Directory**
	- Open your terminal and navigate to the directory where you want your project folder created.
	```
	ParentDirectory/
	└── your-repo-name/     -- Created automatically by git clone
	    └── (Project files)
	```
3. **Clone Your New Repository**
	```bash
	git clone https://github.com/your-username/your-repo-name.git
	cd your-repo-name
	code .
	```
4. **Start Developing**
	- Connect Roblox Studio using the Roblox Script Sync plugin and start building.

### Option 2: Clone This Repository Directly

If you prefer to clone this repository directly to inspect or build upon it:

```bash
git clone https://github.com/Distracted-Games/RobloxProjectTemplate.git
cd RobloxProjectTemplate
code .
```

> 💡 **Tip**: If you choose this route and want to publish your own repository, remove the `.git` folder (`rm -rf .git`), run `git init`, and push to your fresh remote.

### Option 3: Using VS Code Source Control UI

If you prefer the VS Code interface over the command line:

1. Copy the repository clone URL from GitHub.
2. In VS Code, open the Command Palette (`Ctrl + Shift + P` or `Cmd + Shift + P`) and run **`Git: Clone`**.
3. Paste the URL, press `Enter`, and select your destination folder.
4. When prompted, click **Open Repository** to open the workspace.

---

## Architecture & Primary Systems

This template ships with an end-to-end game framework designed around strict typing, single-responsibility modules, and non-blocking asynchronous lifecycles.

```
src/
├── ReplicatedFirst/
│   └── ClientStart.client.luau      -- Client bootstrap entry point
├── ReplicatedStorage/
│   └── Source/
│       ├── ModuleLoader.luau        -- Two-pass lifecycle bootstrapper
│       ├── Controllers/             -- Client controllers (Data, Input, Audio)
│       ├── Libs/                    -- Client & shared libraries (Remotes, LeanPromise)
│       ├── Types/                   -- Shared Luau type definitions
│       ├── UI/                      -- UI controllers and View components
│       └── Utility/                 -- Shared helpers (TableUtil, Logger, Connections)
└── ServerScriptService/
    ├── ServerStart.server.luau      -- Server bootstrap entry point
    ├── Libs/                        -- Server libraries (ProfileStore2, SafeTeleport)
    └── Services/                    -- Server services (PlayerDataService)
```

---

### ModuleLoader

The core bootstrapper responsible for scanning and initializing all modules across client and server environments.

* **Two-Phase Lifecycle**:
  1. `Setup()`: Initializes internal state, cached references, and independent variables concurrently across all modules.
  2. `Start()`: Triggered only after all modules have completed `Setup()`. Safe for cross-module dependencies, event listeners, and game activation.
* **Resilient**: Wraps lifecycle execution in retry mechanisms and warns if a module yields unexpectedly (>3 seconds).
* **Promise-Driven**: Exposes `ModuleLoader.WaitForReadyAsync()` and `ModuleLoader.GameReadySignal` for coordinating initial startup logic.

> 📖 *For detailed documentation, configuration options, and lifecycle internals, see the [ModuleLoader Repository](https://github.com/Distracted-Games/ModuleLoader).*

---

### Data Stack (PlayerDataService & DataController)

A full-stack player data management solution combining resilient server persistence with instant client responsiveness.

#### Server: `PlayerDataService`
* **Session Locking**: Powered by [ProfileStore2](https://github.com/Distracted-Games/ProfileStore2) to prevent multi-server profile collisions and data corruption.
* **GDPR Compliance**: Automatically registers `player.UserId` for compliance.
* **Schema Reconciliation**: Automatically applies missing fields from `DefaultPlayerData` to existing player profiles.
* **Safe Mutations**: The `UpdateData(player, mutatorFunc)` method deep-clones working data, executes your mutation safely within a `pcall`, computes exact table deltas using `TableUtil.Diff`, and updates authoritative storage.
* **Delta Replication**: `DataReplicationService` broadcasts only changed keys (`Deltas`) to the client over [Remotes](https://github.com/Distracted-Games/Remotes), minimizing network bandwidth.

#### Client: `DataController`
* **Optimistic Updates**: Mutate state client-side immediately without waiting for server network round-trips.
* **Automatic Reconciliation**: Automatically reconciles pending client transactions when authoritative server deltas arrive, rolling back rejected actions seamlessly.
* **Authoritative vs. Effective Data**: Distinguishes between instant projected state (`DataController.Get()`) and verified server state (`DataController.GetAuthoritativeData()`), ideal for purchases or high-stakes transactions.

```lua
--!strict
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const DataController = require(ReplicatedStorage.Source.Controllers.DataController)

-- Optimistically spend currency locally; rolls back automatically if rejected by the server
DataController.ApplyOptimisticTransaction(function(state)
	state.Coins -= 50
end)
```

---

### UI Management (MVC Architecture)

UI in this template follows a clean **MVC / simplified MVVM model** (without view-models). Rather than introducing the overhead of complex external reactive libraries (such as React-lua or Roact), UI state and rendering are decoupled natively:

* **Views** (`src/ReplicatedStorage/Source/UI/Views/`): Encapsulate visual Roblox UI instances (CanvasGroups, Frames, Tweens, and user input events). Views expose simple interfaces (`Open`, `Close`, `Confirm`) and know nothing about game services.
* **Controllers** (`UIWindowController`, `NotificationController`): Act as the controller layer, handling business logic, server communication, navigation state, and orchestrating Views.

#### `UIWindowController` Highlights
* **LIFO Navigation Stack**: Supports nested menus and modal stacks (`OpenWindow`, `CloseWindow`, `PopWindow`, `CloseAll`).
* **Modal Polish**: Automatically manages dimming backdrops with click-to-dismiss, subtle camera FOV focus tweens, and depth-of-field blur effects.
* **Universal Controls**: Automatically binds "CloseWindow" `InputAction` to close the topmost modal.
* **Promise-Based Confirmations**: Built-in `ShowConfirmDialog` returns a Promise that resolves to the player's choice.

```lua
--!strict
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const UIWindowController = require(ReplicatedStorage.Source.UI.UIWindowController)

-- Open a registered modal window
UIWindowController.OpenWindow("Settings")

-- Prompt an asynchronous confirmation modal
UIWindowController.ShowConfirmDialog({
	Title = "Confirm Purchase",
	Message = "Are you sure you want to purchase this upgrade?",
	ConfirmText = "Purchase",
	CancelText = "Cancel",
}):andThen(function(confirmed: boolean)
	if confirmed then
		-- Execute purchase
	end
end)
```

---

### InputController

An action-based input manager built directly on Roblox's modern **`InputContext`** and **`InputAction`** architecture (replacing legacy `ContextActionService` and `UserInputService` boilerplate).

* **Context Stacking**: Dynamically enable or disable contextual input layers (e.g. `Gameplay`, `UserInterface`, `Driving`).
* **Unified Event Dispatch**: Exposes strongly typed signals for input triggers (`OnActionPressed`, `OnActionReleased`, `OnActionChanged`).
* **Auto-Replication**: Automatically clones default `Inputs` context structures to newly connected players on join.
* **Server Authority Ready**: Built directly on the Input Action System, ensuring full native compatibility with Roblox's [Server Authority model](https://create.roblox.com/docs/en-us/projects/server-authority) for input prediction and validation.

```lua
--!strict
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const InputController = require(ReplicatedStorage.Source.Controllers.InputController)

-- Enable or disable input contexts
InputController.SetContextEnabled("Gameplay", true)

-- Listen to action events
InputController.OnActionPressed:Connect(function(actionName: string, contextName: string)
	if actionName == "Interact" then
		-- Handle interaction logic
	end
end)
```

---

### AudioController

A modern sound management service built entirely on Roblox's **Next-Gen Audio API** (`AudioDeviceOutput`, `AudioPlayer`, `AudioListener`, and `Wire`), bypassing legacy `Sound` instances.

* **Spatial & Direct Routing**: Clones and connects an `AudioListener` directly to `workspace.CurrentCamera` and routes sound output through hardware device outputs.
* **Automatic Lifecycle Cleanup**: `AudioController.PlaySoundToOutput` handles dynamic wiring, volume configuration, playback, and debris cleanup upon completion.

```lua
--!strict
const SoundService = game:GetService("SoundService")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const AudioController = require(ReplicatedStorage.Source.Controllers.AudioController)

local clickAudioPlayer = SoundService:WaitForChild("ClickPlayer") :: AudioPlayer
AudioController.PlaySoundToOutput(clickAudioPlayer, 0.8)
```

---

### SafeTeleport

A server-side teleportation utility that replaces raw `TeleportService:TeleportAsync` calls with hardened, fail-safe mechanics.

* **Retry & Flood Backoff**: Distinguishes between transient failure conditions and rate-limiting (`Enum.TeleportResult.Flooded`), automatically managing backoff intervals and retry quotas.
* **Client Synchronization**: Fires `Teleporting` and `TeleportFailed` network events to notify client UI, allowing you to show loading screens or failure alerts.
* **Client Teleport Bridge**: Listens for client-requested teleports (`InitiateTeleport`) and verifies execution securely on the server.

```lua
--!strict
const SafeTeleport = require("../Libs/SafeTeleport")

-- Safely teleport a player with automated retries and UI event dispatching
SafeTeleport.Teleport(player, targetPlaceId, teleportOptions)
```

---

## Prevalent Libraries & Utilities

### Open-Source Libraries

The template incorporates several standalone open-source libraries. For detailed guides, installation instructions, and full API documentation, visit their individual repositories:

| Library | Description | Repository |
| :--- | :--- | :--- |
| **Remotes** | Zero-boilerplate, strictly typed remote management layer with automatic instance generation, folder hierarchy management, and built-in middleware (`RateLimit`, `Proximity`, `Admin`). | [Distracted-Games/Remotes](https://github.com/Distracted-Games/Remotes) |
| **ProfileStore2** | A fully modular, strictly typed, asynchronous, and non-blocking session-locked data persistence library refactored from ProfileStore. | [Distracted-Games/ProfileStore2](https://github.com/Distracted-Games/ProfileStore2) |
| **LeanPromise** | A modern, strictly typed, feature-complete refactor of evaera's Promise.lua, aligned with idiomatic Luau. | [Distracted-Games/LeanPromise](https://github.com/Distracted-Games/LeanPromise) |
| **ModuleLoader** | A robust two-pass, Promise-driven bootstrapper for client and server module lifecycles. | [Distracted-Games/ModuleLoader](https://github.com/Distracted-Games/ModuleLoader) |
| **Logger** | A lightweight, typed logger featuring call-site context tracking, log levels (`debug`, `warn`, `error`), and table serialization. | [Distracted-Games/Logger](https://github.com/Distracted-Games/Logger) |
| **TypeFunctions** | Reusable Luau user-defined type functions (`EnumOf<T>`, `FromEnum<T>`, `AddKeyIndexer<T>`) designed for the new Luau type solver. | [Distracted-Games/TypeFunctions](https://github.com/Distracted-Games/TypeFunctions) |

---

### Built-In Utilities

Included directly in `src/ReplicatedStorage/Source/Utility/`:

#### `TableUtil`
High-performance table operations for immutable state handling and network delta synchronization:
* `TableUtil.Diff(original, updated)`: Performs deep recursive diffing, producing a delta map with explicit tombstone deletion markers (`DELETE = "\0__DIFF_DELETE__\0"`).
* `TableUtil.Apply(target, deltas)`: Patches a table in-place using a delta map.
* `TableUtil.DeepClone(tbl)` / `TableUtil.DeepFreeze(tbl)` / `TableUtil.DeepFreezeClone(tbl)`: Recursive deep cloning and freezing utilities for immutable data snapshots.

#### `Connections`
A lightweight connection lifecycle manager:
* Collects and tracks arbitrary `RBXScriptConnection` and custom signal connections.
* Provides `Add(...)`, `Remove(...)`, `RemoveAndDisconnect(...)`, and `Disconnect()` for reliable one-step cleanup when an object or view is destroyed.

---

## Development Tools & Setup

This template is configured out-of-the-box to support an efficient, professional Roblox development workflow:

### Roblox Script Sync & Luau LSP
* **Roblox Script Sync**: Used for real-time bidirectional syncing between your local filesystem and Roblox Studio.
* **Luau Language Server**: Provides intelligent auto-completion, navigation, type checking, and documentation popups within VS Code via the companion plugin.

### Static Analysis & Code Formatting
* **Selene** (`selene.toml`): High-performance linter configured with standard Roblox globals to catch syntax mistakes, undeclared variables, and code smell early.
* **Stylua** (`stylua.toml`): Automated opinionated code formatting adhering to the Roblox Luau Style Guide (tabs for indentation, double quotes, no semicolons, and sorted requires).

### Roblox Server Authority Ready
This project template is architected out-of-the-box to support Roblox's [Server Authority model](https://create.roblox.com/docs/en-us/projects/server-authority), enabling responsive, cheat-resistant gameplay for competitive experiences (such as FPS, combat, or racing):

* **Input Action System Native**: Built directly on Roblox's new `InputAction` and `InputContext` architecture (`Workspace.PlayerScriptsUseInputActionSystem`), a mandatory prerequisite for server authority netcode and client-side input prediction.
* **Shared Simulation Discovery**: [`ModuleLoader`](src/ReplicatedStorage/Source/ModuleLoader.luau) includes a built-in `ServerAuthority` configuration flag (`config.ServerAuthority = true`) that automatically discovers and initializes shared simulation modules located under `ReplicatedStorage.Source.Simulation` on both the client and server.
* **Prediction & Resimulation Friendly**: Decoupled state management and action-based input dispatch make it straightforward to hook client prediction, rollback, and resimulation loops directly into `RunService:BindToSimulation()`.
* **Activating Server Authority**: In Roblox Studio, set `Workspace.AuthorityMode` to `Enum.AuthorityMode.Server` (which automatically configures fixed simulation, deferred signals, streaming, and input action replication), enable `ServerAuthority = true` in `ModuleLoader.luau`, and place your simulation modules in `ReplicatedStorage.Source.Simulation`.

---

## VS Code Workspace Configuration

The included `.vscode/settings.json` file configures your VS Code workspace for optimal Luau development:

* **Strict Formatting**: Format-on-save enabled with Stylua for both `.lua` and `.luau` files.
* **Visual Guidelines**: Column rulers set at 80 and 100 characters to encourage readable, maintainable line lengths.
* **Roblox Theming**: Custom folder icons for Roblox services powered by Material Icon Theme.
* **Diagnostics & Autocomplete**: Configured Luau Language Server definitions with auto-import support.

### Recommended Extensions

Install the following VS Code extensions to take full advantage of this workspace configuration:

* [Luau Language Server](https://marketplace.visualstudio.com/items?itemName=JohnnyMorganz.luau-lsp) (`JohnnyMorganz.luau-lsp`)
* [Selene Linter](https://marketplace.visualstudio.com/items?itemName=Kampfkarren.selene-vscode) (`Kampfkarren.selene-vscode`)
* [StyLua Formatter](https://marketplace.visualstudio.com/items?itemName=JohnnyMorganz.stylua) (`JohnnyMorganz.stylua`)
* [Material Icon Theme](https://marketplace.visualstudio.com/items?itemName=PKief.material-icon-theme) (`PKief.material-icon-theme`)

---

## Contributing & Feedback

If you find this template helpful, find a bug, or have suggestions for improvements, feel free to open an issue or submit a pull request on [GitHub](https://github.com/Distracted-Games/RobloxProjectTemplate).
