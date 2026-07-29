# SCOPES — blank_node two-layer architecture

## Layers

blank_node separates concerns into two scopes that reflect the two ways a session can run:

**Conversational** — real-time, human-present. The owner is actively messaging.
Latency matters. Tone matters. The layer stays alive continuously.

**Executional** — autonomous, headless. The owner is not present. A timer fires, work happens, the process exits. The layer runs in bursts.

---

## Directory mapping

```
scripts/
  conversational/       # launched by conversation@.service — runs continuously
    conversation.sh       # main conversational loop (Telegram ↔ Claude)
    voice_conversation.sh # voice mode (wake-word + STT + TTS)
    home_tts_play.sh      # local TTS playback
    conversation@.service
    conv-watchdog@.{service,timer}
    channel-duration-watchdog@.{service,timer}

  executional/          # launched by night-agent@.service / interactive.sh
    wake.sh               # main launcher — all trigger modes, all gates
    interactive.sh        # owner-triggered interactive (manual mode)
    resolve_session_type.py  # session type dispatcher (reads Loom queue state)
    splice_prompt.py         # wrapper + goal prompt construction
    check_window.py          # session schedule window checker
    request_replan.py        # escape hatch: transition task to needs_plan
    tag_skill_lookup.py      # SOP skill tag resolver
    night-agent@.{service,timer}
    emergency-agent@.{service,timer}
    argus-poller.{service,timer}
    web-ui@.service

  nexus-watcher.service # cross-layer: polls Nexus regardless of which layer is active

tools/
  conversational/       # owned by / called from the conversational layer
    telegram_send.sh      # send Telegram message to owner
    telegram_watcher.py   # long-poll Telegram watcher
    telegram_webhook_handler.py
    telegram_check.sh     # legacy polling fallback
    command_dispatcher.py # /command handler
    check_replies.sh      # read incoming messages at session start
    check_conv_status.sh  # conversation layer health check
    update_conv_budget.py # context budget counters
    conv_watchdog.py               # idle-timeout watchdog
    conv_idle_check.py             # companion to conv_watchdog.py
    channel_duration_watchdog.py   # force-closes over-long agent-channel sessions
    recap_generator.py    # catch-up recap for returning conversation sessions
    home_stt.py           # speech-to-text
    home_record.py        # microphone capture
    wake_word_listener.py # wake-word detection
    fish_tts_send.sh      # Fish Audio TTS → Telegram voice note
    tts_send.sh           # ElevenLabs TTS → Telegram voice note

  executional/          # owned by / called from the executional layer
    check_session.sh      # --time / --context / --usage checks
    health_check.sh       # structural sanity sweep
    emergency_mode.sh     # toggle emergency timer (on|off)
    goal_switch.sh        # switch active Loom goal
    session_trigger_server.py  # HTTP server for manual triggers (port 8766)
    behavioral_adapter.py      # generate behavioral context flags
    relationship_update.py     # update trust/warmth/friction axes
    analytics_write.py         # write session analytics to analytics.db
    session_report.py          # session report generator
    session_digest.py          # multi-session summary
    milestone_report.py        # milestone-based report
    daily_digest.py            # daily digest for owner
    owner_brief.py             # returning-owner briefing
    wonder_module.py           # philosophy session exploration
    surface_blockers.py        # show blocked tasks
    notify_task_complete.py    # task completion ping
    report_archive.py          # FTS archive for session reports
    drift_report.py            # agent_project vs blank_node diff
    codebase_indexer.py        # structural codebase map
    codebase_narrative.py      # narrative codebase description
    session_embed.py           # embed sessions into analytics.db vector index
    analytics_search.py        # semantic search over analytics
    memory_search.py           # search memory files
    significance_classifier.py # classify session significance
    consolidate_session.sh     # post-session significance + narrative
    argus_context_poller.py    # Argus context polling
    index_check.py             # codebase index freshness check
    test_session_type.py       # integration test for session type resolver
    schedule_one_off.py        # schedule one-off sessions via systemd-run
    check_character.sh         # style drift check (kaomoji %, apologist phrases)
    loom.sh                    # Loom CLI convenience wrapper
    scan_file_inbox.py         # process file-based inbox items

  # Cross-layer seam (root of tools/) — accessible from both layers
  inbox.py              # startup|read|append|prune — message queue to agent
  outbox.py             # send|drain|check — agent → owner delivery
  nexus_watcher.py      # Nexus message polling
```

---

## Seam (cross-layer)

Three files live at `tools/` root because both layers read or write them:

- **`inbox.py`** — the executional layer reads pending messages at wake; the conversational layer appends incoming Telegram messages
- **`outbox.py`** — both layers queue outbound messages here; the executional layer drains on exit
- **`nexus_watcher.py`** — Nexus polling is orthogonal to session type; runs regardless

---

## Decision rule

When adding a new file, ask: which layer calls it first?

- Called by `conversation.sh` or from inside a live Telegram session → `tools/conversational/` or `scripts/conversational/`
- Called by `wake.sh` or from inside a headless session → `tools/executional/` or `scripts/executional/`
- Called by both, or by neither (standalone daemon) → `tools/` root or `scripts/` root
