---
name: splunk-explain-spl
description: Explain a Splunk SPL search in plain language and flag cost or safety issues
---

# Explain SPL

Take the SPL from the user (or the last search in this chat).

1. Call `saia_explain_spl` when that tool exists.
2. If it does not, explain each command in order: what it filters, what it transforms, and what it outputs.
3. Flag missing index/time bounds, `join`/`transaction`, unbounded time, and anything `splunk_run_query` would reject (destructive commands, likely timeout, likely >1000 events).
4. Offer one tighter rewrite. Do not run it unless the user asks.
