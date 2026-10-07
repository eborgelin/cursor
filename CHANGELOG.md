# Changelog

All notable changes to this plugin will be documented here.

## 1.0.0 — initial release

- Added the `splunk` MCP server using streamable HTTP. The URL and encrypted token are plugin variables (`${SPLUNK_MCP_URL}`, `${SPLUNK_MCP_TOKEN}`) sent as `Authorization: Bearer`.
- Documented setup against the Splunk MCP Server app (GA as of 1.0.0), including the deprecated On-Cloud `*.api.scs.splunk.com` endpoint.
- Added skills for search, investigation, SPL authoring, Dashboard Studio, and visual design.
- Added slash commands: `splunk-search`, `splunk-investigate`, `splunk-health`, `splunk-explain-spl`, `splunk-dashboard`.
- Added agents: `splunk-sre`, `splunk-spl-author`.
- Added an always-on rule for MCP-only access, search guardrails, and credential handling.
- Logo: original log-search mark (not a Splunk trademark).
