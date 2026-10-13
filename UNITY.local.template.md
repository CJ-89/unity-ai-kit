# Project-specific Unity notes

Owned by this project. The agent may amend this file when the user asks. Never put secrets here.
Generic lessons (true for any Unity project) belong in the kit's `UNITY.md` / `UNITY-EDITOR.md` instead.
Claude Code loads this file at the start of every session, so keep it short and factual.

## Project facts
- Game: (one line: genre, core loop)
- Editor: (Unity version). Scenes: (list)
- Android: Min SDK (fill in), Target API floor: see `.unity-kit.env`
- Bundle Version Code: check Player Settings AND the Android Build Profile (the profile wins at build time)
- Input: (Input Manager / Input System)
- Plugins/SDKs of note: (e.g. ad SDK, Play Games)
- Signing: keystore settings live in `~/.config/unity-kit/projects/<ProjectFolderName>.env`
- AI tooling: MCP for Unity (version pinned in `Packages/manifest.json`), see `docs/ai/UNITY-EDITOR.md`

## Code map
(Ask the agent: "Fill in the code map in docs/ai/UNITY.local.md using UnityMCP to inspect the scene." One line per
important script: what it owns, which events it fires/listens to. Note string lookups such as tags or child names.)

## Known issues / candidates for improvement
- (filled in by audits)

## Decisions and history
- (date) (what changed and why)
