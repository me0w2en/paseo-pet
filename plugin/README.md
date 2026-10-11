# Paseo Pet Bridge

Paseo plugin that streams agent completions, failures, and permission requests to a desktop pet over a local token-authenticated SSE API, and lets the pet approve or deny permissions.

## Install

```bash
paseo plugin install npm:paseo-pet-bridge
```

Then build and run the PaseoPet macOS app. See the [full README](https://github.com/me0w2en/paseo-pet#readme) for the app, skins, and Codex Pet support.

## API

All endpoints listen on `127.0.0.1` (port 6792 or the next free port up to 6801) and require `Authorization: Bearer <token>`. The URL and token are written to `~/.paseo/pet-bridge/connection.json` (mode 0600) each time the plugin starts. Requests that carry an `Origin` header are rejected.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/state` | Current agents and pending permissions |
| `GET` | `/v1/events` | SSE stream: `snapshot` and `notice` events |
| `POST` | `/v1/agents/:agentId/permissions/:requestId` | Body `{"behavior":"allow"\|"deny"}` |
| `POST` | `/v1/test` | Emit a test notice |

## Limitations

- Events are live and best-effort; missed events are not replayed.
- Subagent completions are not announced.

## License

[MIT](LICENSE)
