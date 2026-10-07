# Splunk

Cursor plugin that connects agents to [Splunk](https://www.splunk.com) through Splunk's first-party [MCP Server for Splunk platform](https://help.splunk.com/en/splunk-cloud-platform/mcp-server-for-splunk-platform/1.1/about-mcp-server-for-splunk-platform).

Run SPL, inspect indexes and knowledge objects, investigate incidents, and draft Dashboard Studio definitions — under the permissions of the encrypted MCP token you provide.

## Install

1. Open **Cursor Settings → Plugins**.
2. Search for **Splunk**, or add this repository.
3. Click **Install**, then set the MCP server URL and encrypted token (below).

Or run `/add-plugin splunk` in chat.

## MCP

```json
{
  "mcpServers": {
    "splunk": {
      "type": "http",
      "url": "${SPLUNK_MCP_URL}",
      "headers": {
        "Authorization": "Bearer ${SPLUNK_MCP_TOKEN}"
      }
    }
  }
}
```

Auth is an encrypted Splunk MCP token sent as `Authorization: Bearer`. The plugin does not store secrets; you set the values in **Dashboard → Plugins → Configure**.

Cursor talks to the server over streamable HTTP. Node.js and `mcp-remote` are not required for this plugin.

## Setup

The Splunk MCP Server is a Splunkbase app on your search head (Cloud or Enterprise). The legacy On-Cloud endpoint `*.api.scs.splunk.com` is deprecated — new deployments must use the app.

### 1. Install and authorize the app

1. Install [MCP Server for Splunk platform](https://splunkbase.splunk.com/app/7931) on the search head or search head cluster.
2. Enable REST API access and token authentication on the instance.
3. Grant `mcp_tool_execute` to roles that should call tools. Grant `mcp_tool_admin` to roles that manage tools and create tokens.
4. Optional: install [Splunk AI Assistant](https://splunkbase.splunk.com/app/7245) if you want `saia_generate_spl`, `saia_explain_spl`, `saia_optimize_spl`, and `saia_ask_splunk_question`.

### 2. Copy the endpoint and create a token

1. Open the **Splunk MCP Server** app in Splunk Web.
2. Copy the MCP server endpoint. That value is `SPLUNK_MCP_URL`.
3. Generate an **encrypted authentication token**. Copy it once — that value is `SPLUNK_MCP_TOKEN`.

Encrypted tokens are MCP-only. They cannot be used for direct Splunk REST API calls. Treat them as credentials: do not commit them, paste them into source, or share them.

Creating a token for yourself requires `edit_tokens_own` and `mcp_tool_admin`. Creating a token for another user requires `edit_tokens_all` and `mcp_tool_admin`.

### 3. Configure the plugin

In **Dashboard → Plugins → Configure**, set:

| Variable | Value |
| --- | --- |
| Splunk MCP server URL | Endpoint from the MCP Server app |
| Encrypted MCP token | Token from step 2 |

On a team marketplace an admin can set these once per install. Tool calls still run as the token's Splunk user, including that user's RBAC.

## What agents can do

Core tools are prefixed `splunk_`. AI Assistant tools are prefixed `saia_` and appear only when that app is installed. Administrators can disable tools globally in the MCP Server app.

| Tool | Purpose |
| --- | --- |
| `splunk_run_query` | Run SPL (quick, non-destructive) |
| `splunk_run_saved_search` | Run a named saved search (beta, MCP Server 1.1+) |
| `splunk_get_info` | Instance version and status |
| `splunk_get_indexes` / `splunk_get_index_info` | Index inventory |
| `splunk_get_metadata` | Hosts, sources, sourcetypes |
| `splunk_get_knowledge_objects` | Saved searches, alerts, macros, lookups, data models, views, and related types |
| `splunk_get_user_info` / `splunk_get_user_list` | Current user or user inventory |
| `splunk_get_kv_store_collections` | KV Store stats |
| `saia_generate_spl` | Natural language → SPL |
| `saia_explain_spl` | SPL → natural language |
| `saia_optimize_spl` | Performance rewrite |
| `saia_ask_splunk_question` | Product / SPL Q&A |

The live server is the source of truth for tool names and schemas.

`splunk_run_query` may reject searches that are unsafe or destructive, run longer than 1 minute, or return more than 1000 events.

## Plugin contents

| Kind | Name | Role |
| --- | --- | --- |
| Skill | `splunk-search` | Bounded MCP searches |
| Skill | `splunk-investigate` | Incident timeline and blast radius |
| Skill | `splunk-spl-authoring` | Write and optimize SPL |
| Skill | `splunk-dashboards` | Dashboard Studio JSON / XML |
| Skill | `splunk-dashboard-design` | Layout and visual hierarchy |
| Command | `/splunk-search` | Run a search |
| Command | `/splunk-investigate` | Investigate an incident |
| Command | `/splunk-health` | Instance and index status |
| Command | `/splunk-explain-spl` | Explain a search |
| Command | `/splunk-dashboard` | Draft a dashboard |
| Agent | `splunk-sre` | Read-only incident investigator |
| Agent | `splunk-spl-author` | SPL specialist |
| Rule | `splunk-mcp` | Always-on MCP safety |

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Tools missing after connect | Disabled in the MCP Server app, or Splunk AI Assistant is not installed (`saia_*`) |
| `401` / auth errors | Token expired, invalidated, or not an encrypted MCP token. Create a new token in the app. |
| `403` / empty results | Role lacks `mcp_tool_execute` or index permissions. Check with `splunk_get_user_info`. |
| Search fails immediately | Destructive SPL, runtime over 1 minute, or more than 1000 events. Narrow the query. |
| Client still points at `*.api.scs.splunk.com` | Deprecated On-Cloud endpoint. Install the Splunkbase app and use its URL plus a new encrypted token. |
| TLS errors | The OS does not trust the search head certificate. Fix trust in the OS store; do not disable TLS verification in production. |

After upgrading the MCP Server app from 0.2.x to 1.0.0, old tokens stop working. Create new encrypted tokens and update the plugin variables.

## Observability Cloud (optional)

This plugin targets the **Splunk platform** MCP app (scenario 1 in Splunk's docs). To also load Splunk Observability (o11y) tools, Splunk documents a separate MCP Gateway URL and extra headers (`splunk_tenant`, `X-SF-TOKEN`, `X-SF-REALM`). Configure that gateway in Cursor MCP settings if you need it; do not put those secrets in this repo.

## OAuth (optional)

MCP Server 1.1+ can act as an OAuth 2.1 server on Splunk Cloud stacks where Splunk has enabled it. This plugin ships the GA token flow because every app install supports it. If your stack uses OAuth, you can authenticate the same HTTP endpoint through Cursor's MCP OAuth prompt instead of pasting a token — still restrict scopes to `openid` and `offline_access` as Splunk documents.

## Docs

- About the MCP Server: https://help.splunk.com/en/splunk-cloud-platform/mcp-server-for-splunk-platform/1.1/about-mcp-server-for-splunk-platform
- Configure the app: https://help.splunk.com/en/splunk-cloud-platform/mcp-server-for-splunk-platform/1.1/configure-the-splunk-mcp-server
- Connect a client: https://help.splunk.com/en/splunk-cloud-platform/mcp-server-for-splunk-platform/1.1/connecting-to-the-mcp-server-and-settings
- Tools: https://help.splunk.com/en/splunk-cloud-platform/mcp-server-for-splunk-platform/1.1/mcp-server-tools
- Observability gateway: https://help.splunk.com/en/splunk-cloud-platform/mcp-server-for-splunk-platform/1.1/configure-splunk-observability-tools-with-splunk-mcp-server
- Splunkbase app: https://splunkbase.splunk.com/app/7931

## Publish to the Cursor Marketplace

This repository is a single Cursor plugin (`.cursor-plugin/plugin.json` at the repo root). To list it:

1. Push to a public Git repository.
2. Confirm the [submission checklist](https://cursor.com/docs/reference/plugins): valid kebab-case `name`, relative paths, every `${VAR}` declared in `variables`, logo in-repo, README covers setup.
3. Submit the repository URL at [cursor.com/marketplace/publish](https://cursor.com/marketplace/publish).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Splunk is a trademark of Cisco Systems, Inc. or its affiliates. This plugin is not affiliated with, endorsed by, or sponsored by Cisco or Splunk Inc.
