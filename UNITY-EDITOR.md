# Working through the Unity Editor (generic, kit-owned)

Scope: Unity projects with the MCP for Unity bridge (`com.coplaydev.unity-mcp`, pinned by the kit in `Packages/manifest.json`).
The Editor is usually open and connected to Claude Code as the `UnityMCP` server. Prefer it over guessing.
Project-specific facts live in `docs/ai/UNITY.local.md`. `install.sh --update` replaces this file.

## Loop for every code change
1. Edit the C# file.
2. Ask Unity to refresh/recompile, then read the console. Fix every new `error CS` before doing anything else.
3. For gameplay changes: enter Play Mode briefly, read the console again, exit Play Mode.
4. Only then report the change as done, and say what you verified (compiled, console clean, played).

## Rules
- Scenes, prefabs, components and materials: change them through MCP tools, never by hand-editing `.unity` / `.prefab` /
  `.asset` YAML (breaks GUID and fileID references). Save the scene after editing it.
- `ProjectSettings/*.asset`: change through the Editor (MCP or menus), never on disk while Unity is open (UNITY.md rule 9).
- Make lasting changes only in Edit Mode: anything changed during Play Mode is discarded when Play Mode ends.
- Do not delete assets, folders or packages without asking. Do not change `Packages/manifest.json` without asking.
- One improvement per commit, on a branch. Show the diff of any scene/prefab/settings file that changed.
- Read-only questions ("what does X do", audits) must not change any file.
- Batch builds (`tools/build-aab.sh`) need the Editor closed, which also stops the bridge. Finish Editor work first.
- Only one Unity project should be open while working with Claude: all open editors share one bridge server.
- Settings live in the Editor's memory: to undo a settings change, change it back through the Editor (MCP or menus). `git restore` on
  `ProjectSettings/` or a Build Profile while Unity is open is undone by Unity's next save.
- With an active Build Profile, the PlayerSettings API writes to that profile's copy. Set the value in Player Settings too and show
  both diffs (UNITY.md rule 8). Never commit a ticked Development Build.
- Persistent objects (`DontDestroyOnLoad`): a scene reload creates a second copy. Guard with
  `if (Instance != null && Instance != this) { Destroy(gameObject); return; }` and clear `Instance` in `OnDestroy`, or create the object
  from `[RuntimeInitializeOnLoadMethod]` instead of placing it in a scene.
- The Device Simulator cannot be driven through MCP (Play Mode renders to the Game view). For safe-area/notch checks use the simulator's
  device data (resolution, dpi, safe area) or ask the user to check, and say which you did.
- Third-party Editor placeholders (ads, consent, sign-in) do not behave like the device (e.g. a placeholder banner vanishes on scene
  reload). Report Editor results as "Editor only" and list what must be checked on a phone.

## Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| `/mcp` shows `✘ UnityMCP` | Bridge server not running (HTTP Local mode) or Unity closed | Open the project; Window > MCP for Unity > Start Server. Keep Advanced > "Auto-Start Server on Editor Load" on. Then `/mcp` > Reconnect |
| Unity tools vanish for a few seconds | Domain reload after a script change | Wait, then retry; `/mcp` > Reconnect if needed |
| Unity log: `Claude CLI not found` | Unity (a GUI app) does not see your shell PATH; it only checks `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, nvm | Install Claude Code and uv with their official installers (they use `~/.local/bin`), restart Unity |
| UnityMCP missing in a new project | Registered only for one folder (local scope) | One-time: `claude mcp add --transport http --scope user UnityMCP http://127.0.0.1:8080/mcp` |
| UnityMCP disappeared everywhere | "Unregister" in the MCP window removes it from all scopes, including user scope | Run the one-time command above again. Do not press Unregister |
| Claude acts on the wrong project | Two editors open on one bridge | Close the other editor, or name the project in the prompt |
| A settings value Claude reverted comes back | Unity rewrote the file from memory | Revert through the Editor, or close Unity before `git restore` |
| Code waits forever for a callback from a native SDK (e.g. consent) | The SDK posts callbacks through a main-thread dispatcher that is only created by a later init call | Create the dispatcher first (for Google Mobile Ads: `MobileAdsEventExecutor.Initialize()` before UMP), then test on a device |
