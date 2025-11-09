# Optional Libraries

This folder contains a collection of **optional**, reusable libraries made available for the Roblox development community.  
These libraries are not part of the core template and are provided as a convenience for developers who want quick access to common systems, utilities, and helper scripts.

Each library is designed to be **self-contained**, **lightweight**, and **easy to integrate** into any Roblox project.

---

## 🧩 Using Optional Libraries

You can freely include any of these libraries in your own project by simply **dragging them into your project's source folder** (for example, `src/ReplicatedStorage/libs`).

Example:
```

src/
└── ReplicatedStorage/
    └── libs/
    ├── Signal/
    │   ├── init.lua
    │   └── Connection.lua
    ├── Promise/
    │   ├── init.lua
    │   └── Scheduler.lua
    └── TableUtil.lua

````
> *Note*: The above mentioned libraries are not neccesarily included and are just example names.

Once added, you can require them like any other module:
```lua
local Signal = require(ReplicatedStorage.libs.Signal)
````

> 💡 *Tip*: You can remove this entire folder if you don’t plan to use any of these libraries.
> They are not referenced by the template and will not affect your project.

---

## 💭 Library Design Philosophy

Each library in this collection follows a few simple principles:

* **Independence** — No dependencies on the core template or other libraries (though the [Modular Framework](/OptionalLibraries/ModularFramework/) is often mentioned or used by default).
* **Readability** — Code is structured and (*over*-)commented for easy learning and modification.
* **Reusability** — Designed to be portable between different Roblox projects.
* **Performance Awareness** — Built with efficient patterns suitable for real-time games.

---

## 🧠 Contributing

Contributions are welcome!
If you’d like to add your own libraries or improve existing ones:

1. Follow the structure and style of existing libraries. Only quality code will be accepted.
2. Include clear documentation at the top of each file (purpose, parameters, return values, etc.). Optionally, also include a detailed README.
3. Submit a pull request describing your additions or changes.

---

## 📚 Examples of Included Libraries

| Library Name          | Description                                                                   |
| --------------------- | ----------------------------------------------------------------------------- |
| `ModularFramework`    | Robust framework for handling a "single-script" structure.                    |
| `DayNightCycle`       | Simple implementation of a day/night cycle with time-of-day events.           |
| `Logger`              | Robust debug logging tool to replace using multiple debug print strings.      |
| `getInstance`         | Safely access nested instances by path with automatic error handling.         |
| `Network`             | Type-safe wrapper for RemoteEvents and RemoteFunctions, with automatic setup and safe client/server invocation.   |

*(The available libraries may change over time as new tools are added or improved.)*

---

## ⚙️ Versioning & Updates

The optional libraries are versioned alongside this repository.
Future updates may include improvements, optimizations, or new additions.
You can always check the commit history or compare versions to see what’s new. I will do my best to update the version number in the top comment.

---

If you find these libraries helpful or have suggestions for future additions, feel free to open an issue or submit a pull request!
