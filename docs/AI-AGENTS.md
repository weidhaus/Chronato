# AI agents in Chronato

Chronato lets coding agents (Claude Code, Codex CLI, Cursor, any MCP client) book
their own working time in Kimai. The agent talks to `Chronato mcp`, a small
[Model Context Protocol](https://modelcontextprotocol.io) server inside the app
binary, and calls `start_tracking` / `stop_tracking` around its tasks.

## How AI time is booked

- **Separate Kimai user.** AI time goes to the Kimai user chosen under
  Settings → AI Agents (suggested: a user named `Claude`). Your own hours stay
  yours and reports show AI time separately, provided Kimai is set up for it
  (see [What Kimai needs](#what-kimai-needs)). With "Me" as the booking user, AI
  time lands on your own timesheet, told apart from yours only by its tag.
- **Tagged per agent.** Every entry carries the tag `ai-<agent>`, e.g. `ai-claude-code`.
  Kimai's API silently drops tags that don't exist yet, so Chronato creates the
  tag when you add the agent and checks it again before every booking. An entry
  Kimai saved without its tag is reported as an error, never as booked.
- **Booked when finished, never as a running timer.** Kimai allows one running
  timer per user. While an agent works, Chronato keeps an open session on disk
  (`~/Library/Application Support/Chronato/sessions/`) and shows it in the menu.
  On `stop_tracking` it books one finished entry (begin + end). Your own timer is
  never touched.
- **When a session ends.** Entries are at least one minute and at most 24 h long.
  - `stop_tracking` ends it at that moment; `start_tracking` while a task is open
    ends the open one at that moment. If Kimai can't be reached, Chronato keeps the
    stop time and books the session once Kimai is back.
  - A session that is never stopped is booked up to the agent's **last call** to
    Chronato: when the client quits or crashes, the terminal is closed, the agent
    is disabled, removed or given a new token, or the session is still open after
    24 h. Agents only reach Chronato through its tools, so a forgotten
    `stop_tracking` books little time rather than the client's idle hours.
  - A session Kimai refuses to book (for example its project was archived) stays
    in the menu as "Not booked" with Kimai's reason, you get a notification, and
    Chronato retries every few minutes. Right-click it to discard it.
  - A session belongs to the Kimai server it was started on and is never booked
    into another one.

## What Kimai needs

Default Kimai roles, checked against Kimai's source:

- **HTTPS.** Chronato only talks to Kimai over HTTPS (plain http only for a
  Kimai on this Mac, `localhost`).
- **A Kimai user for the AI**, e.g. `Claude`, with access to the projects the
  agents work on. Leave "System account" unticked: Kimai refuses to book time for
  system accounts.
- **The API token's user** (the one you connected Chronato with) needs:
  - `create_other_timesheet` to book as another user (Teamlead, Admin and Super
    Admin have it; a Teamlead only for members of their teams),
  - `view_user` for other users to appear in "Book AI time as" (Super Admin only
    by default; otherwise only "Me" is offered),
  - `create_tag` to create the `ai-<agent>` tags (every role has it; or create
    the tags under Kimai → Tags yourself).
  - In Kimai's punch-in/out or duration tracking modes, setting begin and end needs
    `view_other_timesheet` too; the default tracking mode needs nothing extra.
- **Agents working at the same time** book overlapping entries for the same
  user. Keep Kimai's "allow overlapping records" on (the default), or Kimai
  refuses the later ones and the menu shows them as "Not booked".

## 1. Allow the agent

1. Connect Chronato to Kimai (Settings → Connection).
2. Settings → AI Agents: pick the Kimai user AI time is booked as, and
   optionally a default project and activity (used when the agent names none).
   These belong to the server you are connected to: after connecting to another
   Kimai, Settings asks you to set them up again before agents can book there.
3. Add an agent, e.g. "Claude Code" (its name becomes `claude-code`). Chronato
   shows its **token once**; it stores only a hash. Lost it? Get a new one with
   New Token… and run the setup again; the old token stops working at once.
4. Per agent you can set its own default project/activity, or disable it.

Each agent identifies itself with two environment variables:
`CHRONATO_AGENT` (the name) and `CHRONATO_TOKEN`. The examples below use
`<token>` as a placeholder: replace it with the token Settings showed you.

The server command is always the binary inside the installed app:
`/Applications/Chronato.app/Contents/MacOS/Chronato mcp`. Use that path, not a
copy: `Chronato mcp` reads the Kimai connection from the Keychain item the app
stored, and the Keychain only hands it to the same signed binary. Move Chronato
to Applications before you copy a setup: run from the disk image or from
Downloads, macOS gives it a path that disappears later (Settings warns you).

## 2. Register Chronato in your agent

When you add the agent (or get it a new token), Settings → AI Agents → Copy
Setup offers each of the following with the real token and app path filled in.

### Claude Code

Run it in a terminal (Copy Setup → Claude Code):

```sh
claude mcp remove chronato --scope user 2>/dev/null; claude mcp add chronato --scope user -e CHRONATO_AGENT='claude-code' -e CHRONATO_TOKEN='<token>' -- '/Applications/Chronato.app/Contents/MacOS/Chronato' mcp
```

The first part drops an older `chronato` registration (an old token), so the
command can be run again. `--scope user` makes it available in every project.
Check with `claude mcp list`, or `/mcp` inside a session.

### Codex CLI

Add to `~/.codex/config.toml` (Copy Setup → Codex):

```toml
[mcp_servers.chronato]
command = "/Applications/Chronato.app/Contents/MacOS/Chronato"
args = ["mcp"]
env = { CHRONATO_AGENT = "codex", CHRONATO_TOKEN = "<token>" }
```

### Cursor, Claude Desktop and other MCP clients

Most clients read the same JSON block (Copy Setup → JSON):

```json
{
  "mcpServers" : {
    "chronato" : {
      "args" : [
        "mcp"
      ],
      "command" : "/Applications/Chronato.app/Contents/MacOS/Chronato",
      "env" : {
        "CHRONATO_AGENT" : "cursor",
        "CHRONATO_TOKEN" : "<token>"
      }
    }
  }
}
```

- Cursor: `~/.cursor/mcp.json` (all projects) or `.cursor/mcp.json` in a project.
- Claude Desktop: `~/Library/Application Support/Claude/claude_desktop_config.json`.
- Others: wherever the client keeps its `mcpServers`; merge the `chronato` entry in.

Give every client its own agent and token, so its time gets its own tag.

## 3. Tell the agent to use it

The server tells the client when to track, but an explicit line in the agent's
instructions (`CLAUDE.md`, `AGENTS.md`, Cursor rules) makes it reliable:

```md
Track your working time with the chronato MCP server: call start_tracking with a
short description when you begin a task, and stop_tracking when it is done.
```

## Tools

| Tool | Arguments | What it does |
| --- | --- | --- |
| `list_projects` | `search?` | Customers → projects → activities with their ids, plus the defaults. |
| `start_tracking` | `description`, `project_id?`, `activity_id?` | Opens a session. Books the previous one first if one is open. |
| `stop_tracking` | `description?` | Books the open session; replies with the duration and the Kimai entry id. |
| `tracking_status` | | The open session, or "Not tracking." |
| `log_time` | `description`, `project_id?`, `activity_id?`, and `minutes` (1–1440, ending now), `begin` + `minutes`, or `begin` + `end` (ISO 8601) | Books finished work directly. At most 24 h, not in the future, begun within the last 7 days. |

Project and activity come from the call, else the agent's defaults, else the
global AI defaults. The activity must belong to the project, or be a global
activity in a project that allows global activities, just as in Kimai.

## Troubleshooting

- **"This agent is not allowed to track time"**: the name or token doesn't
  match an enabled agent in Settings → AI Agents. Agents and tokens are checked
  on every call, so disabling an agent takes effect immediately.
- **"Chronato is not connected to Kimai yet"**: connect the app first
  (Settings → Connection). Make sure the command points at the installed app.
- **"Chronato could not read its Kimai connection from the Keychain"**: macOS
  refused `Chronato mcp` access (denied prompt, locked keychain, or no screen to
  ask on, e.g. over SSH). Open Chronato once and allow access when asked.
- **"AI agent settings were made for another Kimai server"**: Chronato is now
  connected elsewhere. Open Settings → AI Agents and set them up for this server.
- **"Kimai 400: … should not contain extra fields"**: the API token's user lacks
  a permission Chronato needs (see [What Kimai needs](#what-kimai-needs)).
- **"may not create the tag ai-…"**: create the tag under Kimai → Tags, or give
  the token's user `create_tag`.
- **"No project/activity given and no default configured"**: pass `project_id`
  and `activity_id` (see `list_projects`) or set a default in Settings.
- **Logs**: `Chronato mcp` writes diagnostics to stderr (never the token).
  Claude Code shows them with `claude --debug`; other clients have an MCP log.
- **Try it by hand**:

  ```sh
  echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tracking_status","arguments":{}}}' \
    | CHRONATO_AGENT=claude-code CHRONATO_TOKEN='<token>' /Applications/Chronato.app/Contents/MacOS/Chronato mcp
  ```
