# Roblox Project Template

This repository serves as a public template for my Roblox development setup. It includes configuration for **Rojo**, **Selene**, **Stylua**, and the **Luau Language Server**, along with a growing collection of reusable scripts and functions available to the community.

## 🚀 Getting Started with This Template

You have two options to start using this template for your own Roblox project:

### Option 1: Create a New Repository from This Template

Using the template option is great for a fresh start as it doesn't carry any of the commit history of the current project.

1. **Use the Template**
    - Click the green **"Use this template"** button at the top of the [GitHub repo](https://github.com/Distracted-Games/RobloxProjectTemplate).
    - Select **"Create a new repository"** and fill in your desired repo name and settings.
    - Click the green "**<> Code**" button and copy the repo's URL.
2. **Navigate To Your Desired Local Parent Directory**
    - When you perform the next step below, it will create a copy of the full project folder inside of the directory you run the command from.
    - Make sure you have the **parent** directory open before running the command.
    For example:
    ```
    ParentDirectory/
    └── your-repo-name/ -- The name you created when using the template
        └──  Contents of the RobloxProjectTemplate
    ```
3. **Clone Your New Repository**
    ```bash
    git clone https://github.com/your-username/your-repo-name.git
    cd your-repo-name
    code .
    ```
    💡 Tip: You can paste the copied repo URL when calling `git clone`
4. **Start Developing**
    - Follow the setup instructions below to configure your development environment.

### Option 2: Clone This Repository Directly

If you just want to explore or start from this exact version without making your own repo:
```bash
git clone https://github.com/Distracted-Games/RobloxProjectTemplate.git
cd RobloxProjectTemplate
code .
```
💡 Tip: If you go this route and want to make it your own, consider removing the Git history and pushing to a fresh repo.

### Option 3: Using VS Code UI Rather Than CLI

If you prefer to use the Source Control UI and VS Code commands, follow the steps below:

1. **Use the Template or Clone This Repository Directly**
    - Follow the first step for Option 1 above to use the template or simply copy the URL using the "**<> Code**" button.
2. **Clone the Reposity**
    - Either use the `...` menu at the top of the Source Control UI and select **Clone** or use the Command Palette (`Ctrl + Shift + P`) and type `git clone`.
    - Paste the copied repository URL and press `Enter`.

This should create a copy of the project's folder in the currently opened directory and move you into the project's folder. If you only see the repo's name as a folder in the explorer, then you will want to open it (`Ctrl + K`, `Ctrl + O` or `File > Open Folder...`). When in the correct folder, you should see all the directories and files as they are on GitHub without having to click into anything.

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
