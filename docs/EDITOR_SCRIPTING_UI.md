# Editor: Scripting UI & Workflow

This document describes the editor features added for the in-editor scripting workflow:
- Scripting system integration
- Drag & drop scripts onto GameObjects in the Asset Browser
- Script editor embedded in the Inspector panel
- Script-related toolbar/inspector buttons (icons)

Target audience: engine contributors, editor users, and designers who will use or extend the scripting workflow.

## Goals

- Provide a simple, discoverable scripting workflow in the editor.
- Allow designers to attach scripts to GameObjects via drag & drop.
- Provide a lightweight, embeddable script editor in the Inspector for quick edits and reloads.
- Use clear UI icons (buttons) for common script actions (open editor, run, reload, detach).

## High-level UX

1. Importing a script asset (Lua file) into the project `assets/scripts/` (or the editor asset folder) makes it visible in the Asset Browser.
2. To attach a script to a GameObject, drag the script asset from the Asset Browser and drop it into the selected GameObject's Inspector panel.
3. When a GameObject has a script attached, the Inspector shows a "Script" foldout containing:
   - The script asset name (clickable)
   - A small in-place source editor (text area) for quick edits
   - Action buttons (icons) for: Open in external editor, Run once, Reload, Detach
   - A field for script parameters (key/value pairs) exposed to the script system
4. Changes made in the embedded editor can be saved (writes to the asset file) and the scripting system will hot-reload the script (if configured).

## Drag & Drop

- Source: Asset Browser entries whose asset type is `script`.
- Target: Inspector panel when a GameObject is selected.
- Behavior:
  - Visual feedback while hovering: Inspector shows a highlighted drop zone inside the `Script` foldout.
  - Drop semantics:
    - If the GameObject has no script, the dropped script is attached as the primary script.
    - If a script is already attached, the drop offers to replace or add an additional script component.
  - On successful attach, the editor registers the script with the Scene's `ScriptingSystem` and creates a binding (owner entity id + script asset id).

## Inspector Script Editor

- Implementation details:
  - Minimal text area control built on top of ImGui (multiline input). Intended for small edits and quick iteration.
  - The embedded editor does not replace a full IDE — for heavy edits, the "Open External" button launches the user's configured external editor.
  - The Save action writes the current buffer back to the script asset file via the AssetManager.
  - After Save, the editor notifies the `ScriptingSystem` to reload the script (hot-reload). The engine tries to safely swap in the new script definition (best-effort: errors are reported to the console/action queue).

- Inspector layout (compact):
  - [Script name] [Open] [Reload] [Run] [Detach]
  - Multiline editor area (collapsible)
  - Parameters section (key/value editor)

## Buttons / Icons

Recommended buttons and their meanings (icons referenced from editor assets):

- `open_editor` — Opens the script in the external editor (shortcut: Ctrl+E).
- `reload_script` — Force-reload the script asset into the `ScriptingSystem` (shortcut: Ctrl+R).
- `run_script` — Execute the script once in the current scene/context (useful for testing small snippets).
- `detach_script` — Remove script binding from the GameObject.

Icon assets should live under `assets/ui/icons/` (or `assets/textures/` used by the UI):
- `script_open.png`
- `script_reload.png`
- `script_run.png`
- `script_detach.png`

If you add new icons, use the editor's texture import path (see `editor/src/ui/backend/texture_manager.zig`) and call the existing `preloadIcons()` helper to register them with ImGui.

## Scripting System Integration (developer notes)

- The Scene owns a `ScriptingSystem` instance. GameObjects link to script assets by `AssetId`.
- When a script is attached to a GameObject:
  - The `ScriptingSystem` creates a script instance and tracks ownership (entity id)
  - Script lifecycle: load -> instantiate -> run (optional) -> unload
- Hot-reload:
  - On save (from embedded editor) or on `reload_script` action, the editor tells the `AssetManager` to reload the script asset.
  - `ScriptingSystem` receives asset change events and attempts to recompile/re-initialize the script instances.

### Public API (engine-level)

- Scene / ScriptingSystem:
  - `ScriptingSystem.init(thread_pool: *ThreadPool)` — Initializes scripting subsystem and registers with thread pool.
  - `ScriptingSystem.attachScript(entity: EntityId, script_asset: AssetId, params: ?[]ScriptParam)` — Attach a script to an entity.
  - `ScriptingSystem.detachScript(entity: EntityId, script_asset: AssetId)` — Detach one script instance.
  - `ScriptingSystem.reloadScript(script_asset: AssetId)` — Force reload for an asset.
  - `ScriptingSystem.executeScriptOnce(entity: EntityId, script_asset: AssetId)` — Run a script immediately in the current context.

(Refer to `engine/src/ecs/systems/scripting_system.zig` and `engine/src/scripting/script_runner.zig` for current function names and exact signatures.)

## Editor Implementation Notes

- The embedded editor is intentionally lightweight (ImGui multiline input). For a full-featured editor experience, integrate a separate editor component or open an external IDE from the Open button.
- Drag & drop behavior is implemented in the Asset Browser panel and the Inspector; the Asset Browser calls the editor backend to provide an `ImGui` drag source with a `ScriptAssetId` payload and the Inspector accepts that payload when hovering over the `Script` area.
- The asset attach path should use `AssetManager` APIs to lookup the asset by path/ID and create the binding (do not re-read files directly).

## Logging & Error Handling

- Any editor UI logs use the `zephyr.log` API (project-wide logging helper). Avoid `std.debug.print` in editor code.
- On script load or execution errors, the `ScriptingSystem` should push a result into the editor action queue so the Inspector can show compile/runtime messages.

## Troubleshooting & Notes

- If the hot-reload leaves scripts in an inconsistent state, detach and reattach the script or restart the editor.
- If icon textures or fonts fail to display in the editor, ensure the UI textures were loaded via the synchronous texture upload helpers (new APIs in `engine/src/core/texture.zig`) and that ImGui backend's font handling is working (see `editor/src/ui/backend/imgui_backend_vulkan.zig`).

## Migration Guide for Contributors

- Prefer adding new icons via `assets/ui/icons/` and registering them through the UI texture manager helper.
- Keep imports at file top (`@import(...)`), and use `const log = zephyr.log` in editor files.
- When adding public engine APIs for scripting, add docs strings in the code and update this document with any new hooks needed by the Inspector UI.

---

Document last updated: November 1, 2025
