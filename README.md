# understudy

Local proxy that lets a cheap second LLM take over Claude Code's subagent work in one auditable, dependency-free Node script: the main Claude Code session talks to Anthropic as usual, while a designated subagent is transparently routed to a cheaper provider (DeepSeek, which speaks the Anthropic Messages API natively, so no protocol translation is needed).

## Threat model

- Single Node script, zero npm dependencies - nothing downloaded, nothing phoning home.
- Binds to `127.0.0.1` only; unreachable from other machines.
- Outbound hosts are only those in `config.json` (`api.anthropic.com`, `api.deepseek.com`).
- Keys live in local `.env` / `config.json` (or `${ENV_VAR}` references). Traffic stays in memory; logs are console lines only (method, path, route, status).

## Quick start

Requires [Node.js](https://nodejs.org) (any recent LTS) and `claude` on PATH.

```sh
git clone https://github.com/jacostadeleon/understudy.git
cd understudy
cp .env.example .env     # windows: copy .env.example .env - put your key(s) in
```

| Windows | double-click `understudy.cmd` | built-in (PowerShell tray app) |
| macOS | `./start-unix.sh` | status-bar icon: green/red dot, full model picker menu |
| Linux | `./start-unix.sh` | tray icon: `pip3 install --user pystray pillow` + an AppIndicator host |
| any, no GUI | `./start-unix.sh --headless` (keeps proxy alive; Ctrl+C stops it) | none |

`start-unix.sh` also proxies `und.sh` verbs: `./start-unix.sh` behaves like `./und.sh launch` when no GUI toolkit is available.

Double-clicking `understudy.cmd` (Windows) starts the proxy if needed and parks a tray icon:

- **Green dot** = proxy running, red = stopped, orange = not responding.
- Hover tooltip shows current routing.
- Right-click menu: **Launch Claude Code here**, **Show journal**, **Refresh status**, **Start/Stop proxy**, **Route this project via** (pick any model from `config.json`, or `default` to unrouted Claude haiku), **Exit** (leaves the proxy running).
- Picking a model applies instantly - no restart (the proxy re-reads `selected.json` per request).
- Double-click the icon = launch Claude Code.

## How routing works

`~/.claude/agents/understudy-deepseek.md` carries `understudy-route: selected` in its system prompt. Requests bearing that marker use whatever the tray (or `selected.json`) currently selects; everything else passes through to `api.anthropic.com` untouched. Without the proxy running, plain `claude` still works - delegating to the subagent just degrades to a normal Claude request.

If `selected.json` says `{"default": true}`, marker requests also pass through (the subagent then runs on regular Claude haiku).

## Files

- `proxy.mjs` - the proxy (also loads `.env` beside itself at startup).
- `config.json` - port, passthrough upstream, providers, and the `models` list the tray shows.
- `selected.json` - current model pick (written by the tray; read per-request by the proxy).
- `.env` - API keys, e.g. `UNDERSTUDY_DEEPSEEK_KEY=sk-...` (see `.env.example`).
- `tray.ps1` - Windows system-tray controller.
- `tray.py` - macOS status-bar / Linux tray controller (falls back to headless keeper).
- `understudy.cmd` / `und.cmd` / `und.sh` / `start-unix.sh` / `launch-claude.cmd` - launchers.

## Endpoints (localhost only)

- `GET /healthz` - status incl. current selection and uptime.
- `POST /shutdown` - graceful stop (works no matter who started the proxy).
- `POST /v1/messages/count_tokens` - estimate for routed requests, passthrough otherwise.

## Extending

Add a provider under `providers` and a model under `models` in `config.json`, put its key in `.env`; it appears in the tray picker immediately.
