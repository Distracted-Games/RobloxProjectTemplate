# Roblox Project Template

This repository serves as a public template for my Roblox development setup. It includes configuration for **Rojo**, **Selene**, **Stylua**, and the **Luau Language Server**, along with a growing collection of reusable scripts and functions available to the community.

## 🔧 Development Tools & Setup

This template is pre-configured to support a clean and efficient Roblox development workflow:

- **Rojo**: Enables structured project syncing between your local filesystem and Roblox Studio.
- **Selene**: Provides static analysis for Luau code to catch common issues early.
- **Stylua**: Automatically formats Luau code for consistency and readability.
- **Luau Language Server**: Offers intelligent code completion, navigation, and diagnostics.

## 🗂️ Project Structure & Features

- **Service Mapping**: The included `default.project.json` uses `"ignoreUnknownInstances": true` to prevent Rojo from removing existing Roblox instances not explicitly defined in your local project.  
  - ⚠️ *Best Practice*: Create a `/Source` or `/src` folder within each service to separate scripts from assets and maintain a clean structure.

- **Stylua Configuration**: The included `stylua.toml` file ensures that required modules are sorted alphabetically, mirroring the auto-import behavior for services.

- **`/OtherScripts` Folder**: A sandbox directory for experimental or test scripts that are not synced via Rojo.  
  - This folder is listed in `.gitignore` but commented out by default, allowing you to opt in or out of version control.

## 🖥️ VS Code Workspace Configuration

The template includes a `.vscode/settings.json` file to streamline your development experience in Visual Studio Code:

- Semantic highlighting for improved readability
- Format-on-save with Stylua for both `.lua` and `.luau` files  
  > 💡 *Note*: Roblox scripts should use the `.luau` extension to reflect the correct language and tooling support. Many developers still use `.lua` out of habit, but `.luau` is preferred for Roblox projects.
- Custom icon theming for common Roblox services using Material Icon Theme
- Side-by-side diff view for easier code comparison
- Luau Language Server enhancements for auto-imports and completion behavior
- Rulers at 80 and 100 columns to align with Roblox Lua Style Guide

> These settings are designed to work out-of-the-box with the recommended extensions listed below.

### 💡 Recommended Extensions

You can optionally include a `.vscode/extensions.json` file to prompt installation of these tools:

- `evaera.vscode-rojo` — Rojo integration
- `JohnnyMorganz.stylua` — Luau code formatter
- `JohnnyMorganz.luau-lsp` — Luau Language Server support
- `Kampfkarren.selene-vscode` — Selene static analysis
- `PKief.material-icon-theme` — Custom folder icons

## 📦 [Public Scripts & Functions](/PublicModules/)

This template also includes a selection of reusable scripts and utility functions designed to help other developers:

- Modular components for common gameplay systems
- Utility functions for debugging, data handling, and more
- Examples and test cases to illustrate usage

Feel free to explore, adapt, and contribute. These resources are intended to support both beginners and experienced developers working with Roblox Luau.

---

If you find this template useful or have suggestions for improvement, feel free to open an issue or submit a pull request!
