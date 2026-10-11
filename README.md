# Paseo Pet

**English** · [한국어](README.ko.md)

A desktop pet for [Paseo](https://paseo.sh). It sits in a corner of your screen, reacts to what your agents are doing, tells you when a turn finishes or fails, and lets you approve or deny permission requests without opening Paseo.

| Folder | What it is |
| --- | --- |
| `plugin/` | **pet-bridge**, a Paseo plugin that streams agent events over a local SSE API |
| `app/` | **PaseoPet**, the macOS menu-bar app that draws the pet |

## How it works

```
Paseo daemon ─ lifecycle hooks ─▶ pet-bridge (127.0.0.1:6792, token-authenticated SSE)
                                      │  turn start/end, failure, permission requested/resolved
                                      ▼
                              PaseoPet.app (menu bar + always-on-top transparent window)
                                      │  Allow/Deny → POST → SDK respondToPermission
```

- The app UI is currently Korean; menu names in this README are translated.
- Plugin hooks run **in the daemon even with no app window open**, so notifications arrive while Paseo is closed.
- Moods: waiting for connection (purple) · idle (mint) · working (blue, bouncing, gear) · needs approval (orange, wiggle, badge) · done (green, jump, sparkles) · failed (gray, droopy)
- Speech bubbles
  - **Done:** summary of the final reply and an "Open in Paseo" button.
  - **Failed:** the error message.
  - **Permission:** the command to run with **Allow / Deny / Later** buttons. For questions, the button becomes "Answer in Paseo".
- Clicking the pet or a bubble opens that agent directly via the `paseo://h/<serverId>/agent/<agentId>` deep link.
- The pet hides while Paseo is frontmost (toggle in the menu). Drag it anywhere; the position is remembered.
- **Security:** binds to 127.0.0.1 only. A fresh token is written to `~/.paseo/pet-bridge/connection.json` (mode 0600) each time the plugin starts. Requests with an `Origin` header (browsers) are rejected.
- Subagent completions are skipped, because they pile up quickly during orchestration.

The bridge is a small HTTP/SSE API (`GET /v1/state`, `GET /v1/events`, `POST /v1/agents/:id/permissions/:requestId`), so other pet apps can connect to it too.

## Skins

Menu bar 🐾 → **Skin → Open Skins Folder** opens `~/Library/Application Support/PaseoPet/Skins/`. Each subfolder is one skin; put one image per mood in it:

| File | Shown when |
| --- | --- |
| `idle` | Idle (used for any missing mood) |
| `working` | An agent is working |
| `waiting` | Waiting for approval |
| `happy` | A few seconds after a turn completes |
| `sad` | A turn failed |
| `sleeping` | Disconnected from Paseo |

- Supported formats: `.gif` (animated), `.png`, `.jpg`, `.heic`, `.webp`. Transparent square images of about 256 px work well; they're shown at 84 pt.
- A bounce or wiggle is added per mood. For self-animated GIFs, put `{ "motion": false }` in `skin.json` to turn it off.
- Use **Skin → Reload Skins** after changing files. **Default character** restores the built-in pet.

### Codex Pets

Pets from [codex-pets.net](https://codex-pets.net) (an 8-column sprite atlas: `pet.json` + `spritesheet.webp`) work as-is.

- Menu bar 🐾 → **Skin → Import Codex Pet…**, then paste a pet page URL (e.g. `https://codex-pets.net/#/pets/<id>`). The pet is downloaded, installed, and applied.
- Alternatively, unzip a `*.codex-pet.zip` into the skins folder.
- Rows used per mood: idle/disconnected → `idle`, working → `running`, needs approval → `waiting`, done → `jumping`, failed → `failed`.

Pet artwork belongs to its creators and is not included in this repository.

## Install

Requirements: macOS 14+, Paseo 0.11.2+, and Xcode Command Line Tools (to build the app).

```bash
# 1) Turn on Settings → Plugins → "Enable plugins"
#    (or add "pluginsEnabled": true to ~/.paseo/config.json and run `paseo reload`)

# 2) Install the bridge plugin
paseo plugin install github:me0w2en/paseo-pet:plugin
paseo plugin ls            # pet-bridge should be running

# 3) Build the app, move it somewhere permanent, and run it
git clone https://github.com/me0w2en/paseo-pet.git
paseo-pet/app/scripts/build-app.sh
cp -R paseo-pet/app/build/PaseoPet.app ~/Applications/
open ~/Applications/PaseoPet.app
# Launch at login: System Settings → General → Login Items → add PaseoPet.app
```

Menu bar 🐾 → **Test Connection** makes the pet show a "bridge is working" bubble.

To develop the plugin, install it from the clone (`paseo plugin install "$PWD/plugin"`), run `npm install && npm run typecheck` in `plugin/`, and apply changes with `paseo plugin reload pet-bridge`. Build the app with `swift build` in `app/`.

## Uninstall

`paseo plugin remove pet-bridge`, quit PaseoPet from the menu bar, and delete the app. Skins live in `~/Library/Application Support/PaseoPet/`.

## Limitations

- macOS only (AppKit/SwiftUI).
- Events are live and best-effort. Events missed while the pet was closed are not replayed; on reconnect the pet gets a current-state snapshot.
- The app is not code-signed. Build it yourself, or expect a Gatekeeper prompt.

## License

[MIT](LICENSE)
