---
name: splunk-investigate
description: Investigate an incident in Splunk and return a timeline, blast radius, and evidence
---

# Investigate in Splunk

Follow the `splunk-investigate` skill.

1. Collect symptom, start time, and any host/service/correlation id from the user.
2. Orient with `splunk_get_info`, `splunk_get_indexes`, and `splunk_get_metadata`.
3. Reuse saved searches and alerts from `splunk_get_knowledge_objects` when they match.
4. Build a volume and error timeline, then isolate the top entities.
5. Return what happened, when, where, evidence (SPL + short table), blast radius, and a labeled hypothesis.
