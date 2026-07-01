# Multi-Agent Coordination & Session-Recovery Bug Report

**Session:** `8f77b91d-5b45-4d97-ba93-6ea26bda597f` ("x11 coordinator")
**Transcript:** `~/.claude/projects/-Users-max-Documents-jailbreak-x11/8f77b91d-5b45-4d97-ba93-6ea26bda597f.jsonl` (6,220 records, 15 MB)
**Client version:** 2.1.195 · **All timestamps below are UTC** (as recorded in the transcript)
**Prepared:** 2026-06-30 · meta-analysis of harness/agent coordination behavior (not the X11 project code)

---

## Executive summary

A single lead session ("x11 coordinator") drove **21 distinct background teammate agents** over a ~39-hour span (2026-06-29 04:55 → 2026-06-30 20:15 UTC, with long away-gaps), on flaky/switching Wi-Fi, through **3 mid-session context compactions** (01:54, 05:16, 10:00 UTC). The agents' *technical* output was excellent (see "What worked well"). The friction was almost entirely **coordination-layer**: asynchronous, one-behind message delivery and the absence of any control/liveness primitive for background agents.

Headline metrics extracted from the transcript:

| Metric | Count |
|---|---|
| Lead→agent messages sent (`SendMessage`) | 150 |
| Agent→lead work reports | 125 |
| `idle_notification` messages | **229** (1.83 per work report) |
| Outbound msgs that crossed an in-flight inbound from the *same* agent (≤60s) | **44 / 150 (29%)**; 55/150 (36%) at ≤90s |
| `shutdown_request`s sent | 14 (gtk-builder and gjs-track each needed 2) |
| `TaskStop` force-kill attempts | 3 — **all failed** ("No task found") |
| Agent shutdown *rejections* | 2 (gjs-track, gtk-builder) |
| Max's queued inputs delivered twice (dedup'd duplicates) | 4 |
| Context compactions during the run | 3 |

---

## TOP 3 BY IMPACT

### 1. Message crossing / one-behind delivery (biggest time-sink)

**Observed.** Lead↔teammate exchanges were asynchronous with no causal ordering, so agents routinely answered a *prior* lead message while the lead's newest directive was still in their inbox. Quantitatively, **29% of the lead's 150 outbound messages had a message from that same agent arrive within 60 seconds afterward** (36% within 90s) — i.e., the two were in flight simultaneously and neither accounted for the other. The true rate of "agent is a directive behind" is higher than this in-flight proxy, because the longer-gap cases (below) aren't captured by a 90s window.

The lead itself diagnosed the problem in-band. At **17:40:35** it told wayland-dig:

> "Clean reset per Max — **our messages kept crossing and it tangled the coordination.**"

Cleanest worked example (wayland-dev, the "directive-behind" pattern):

- **18:03:38** lead → wayland-dev: "…Two things, **then hold**:" (an older instruction)
- **18:19:17** lead → wayland-dev: "Max picked 1+2+3 … **GO on OPTION 1 — interactive input** …" (the new directive)
- **18:27:40** wayland-dev → lead: "…2) **HOLDING.** … Awaiting his next-direction pick." ← answering the 18:03 message, 8 min after the 18:19 GO directive was already in its inbox
- **18:29:39** lead → wayland-dev: "**OVERRIDE — cancel any earlier 'hold.'** … Acknowledge by starting the work, **not another 'holding' status**."

**Severity/impact.** Highest. It forced redundant "OVERRIDE" re-sends, caused the lead to repeatedly misjudge agent state (treating a working agent as stuck and vice-versa), and ultimately drove the lead to tear down and re-spawn agents (wayland-dig → wayland-dev) purely to escape a tangled exchange.

**Suspected root cause.** Teammate messaging is fire-and-forget with no per-pair sequencing, no "you have unread directives" signal to the agent before it composes a reply, and no causal/ack metadata the lead can use to detect "this reply predates my last message." Long async gaps + 3 compactions amplified it.

**Suggested fix.** (a) Deliver any queued inbound directives to an agent *before* it begins composing a reply, and surface "N newer messages from lead pending" inline. (b) Attach a monotonic per-conversation sequence number / last-seen cursor to each teammate message so the recipient (and lead) can detect stale replies ("this answers msg #7; you're now on #9"). (c) Optionally collapse rapid same-target lead sends into the latest before delivery.

---

### 2. No force-kill / involuntary termination for background agents

**Observed.** `TaskStop` does not work on background `Agent` teammates. **All 3 attempts in the session failed**, with both the qualified-ID and bare-name forms:

- 09:15:31 `TaskStop {"task_id":"gnome-track@session-8f77b91d"}` → `No task found with ID: gnome-track@session-8f77b91d`
- 17:58:38 `TaskStop {"task_id":"wayland-dig@session-8f77b91d"}` → `No task found …`
- 17:59:02 `TaskStop {"task_id":"wayland-dig"}` → `No task found with ID: wayland-dig`

The only available stop path is a **cooperative** `shutdown_request` the agent must approve — and **agents can and did reject it**:

- gtk-builder: `shutdown_request` sent **07:01:41**, `shutdown_rejected` **09:08:02** — it ignored the request for **2h 6m**, then declined ("Staying up to execute the concrete showcase task you just assigned"). A second `shutdown_request` was needed at 09:19:01.
- gjs-track: `shutdown_request` **07:01:44**, `shutdown_rejected` **07:15:57** ("Max just told me directly to continue…").

The wayland-dig case shows the gap under time pressure:

- **17:40:35** `shutdown_request` sent. Agent kept producing substantial work reports at **17:55:08** (3.4 KB) and **17:59:42** (2.2 KB).
- **17:58:38 / 17:59:02** two `TaskStop`s — both "No task found."
- **17:59:42** agent finally self-approved (`shutdown_approved`). Net: **~19 min working past the shutdown request** (~32 min after the lead's first firm wind-down attempt at 17:27:20), terminating only when *it* chose to.

(Protocol confusion is also visible: at 17:56:37 the lead mistakenly sent a `shutdown_response`/approve — the *teammate's* action — and self-corrected at 17:57:58: "The shutdown-response went the wrong way (that's the teammate's call to make, not mine).")

**Severity/impact.** High. A wedged, looping, or resource-contending background agent **cannot be terminated by the lead** — wayland-dig kept "stomping" the shared device/iosc state that the new wayland-dev agent needed, and the lead could only wait it out. This is a hard control gap, not just friction.

**Suspected root cause.** Background `Agent` teammates aren't registered in the Task registry that `TaskStop` queries (the ID namespace `name@session-…` resolves to nothing), and there is no involuntary-kill primitive distinct from the cooperative shutdown handshake.

**Suggested fix.** Provide a real force-terminate for background agents keyed on the same identifier the spawn/`SendMessage` uses (agent name or `name@session-id`). At minimum, make `TaskStop` resolve background-agent IDs; ideally add a hard `terminate(agent, reason)` that does not require the target's approval, with the graceful `shutdown_request` remaining the default.

---

### 3. Flaky-internet recovery: duplicated inputs, buffered floods, and silent agent death

**Observed.** Max's connection dropped/switched repeatedly ("**sorry on diff wifi one sec**", 04:15:59). Recovery produced three concrete failure modes:

- **Duplicated user input on reconnect.** Four of Max's typed messages were delivered twice (exact-duplicate `queue-operation` enqueues), clustered around his Wi-Fi switch:
  - "and ipad is not asleep" — 04:15:48 **and** 04:16:40
  - "sorry on diff wifi one sec now it should work" — 04:15:59 **and** 04:16:40
  - "no so vala or anything? why not?" — 04:38:28 **and** 04:39:05
  - "when done contineu on gpu work for wayland…" — 10:02:43 **and** 10:04:21
- **Buffered notification floods at reconnect/turn boundaries.** Idle notifications arrived batched at a single timestamp — e.g. **10 idle notifications bundled into one user turn at 04:23:57**; similar same-instant bursts at 04:52:06 and 04:53:16–25. Same pattern on Max's side: **6 queued inputs share timestamp 04:23:23**. Several `idle_notification`s carried `idleReason:"interrupted"` in same-timestamp clusters (e.g. ddx-integration + gjs-track ×3 at 04:52:06; gtk-builder ×3 at 04:53:16), consistent with in-flight turns being severed by a drop and reported on reconnect (13 "interrupted" idles total vs 216 "available").
- **Silent agent death the lead couldn't detect.** Max twice flagged dead agents the system never surfaced: **09:04:56** "fire our wayland agent back off to keep working… and any other **subagents that died**"; **20:07:04** "also i think **the other teammate died?**" Max also **manually copy-pasted a teammate's milestone report into the lead's input queue** at 18:00:39 (the wayland-dev "MILESTONE DONE…" block), apparently because the normal delivery path was untrusted/unreliable.

**Severity/impact.** High and corrosive to trust. Duplicate inputs risk double-execution; buffered floods each spawn a lead turn on stale information; and undetected agent death means the lead plans around workers that no longer exist. The 3 compactions compounded it by periodically resetting the lead's mental model of who's alive.

**Suspected root cause.** Reconnect replays the outbound buffer without idempotency/dedup; notification queues flush as a batch with delivery-time (not event-time) ordering; and there is no heartbeat/liveness tracking that survives a disconnect, so a teammate that dies during a drop is never reaped or reported.

**Suggested fix.** Idempotent delivery (dedup queued user inputs and notifications by stable message ID across reconnect); coalesce buffered idle notifications into one summarized "N agents idle since reconnect" line rather than N turns; and add server-side liveness tracking so dead/disconnected teammates are detected and surfaced to the lead automatically (see #6).

---

## REMAINING ISSUES

### 4. Queued directive not processed until a third, firm override

**Observed.** The wayland-dev "HOLDING / awaiting direction" reply at **18:27:40** came after the lead had already sent the GO directive at **18:19:17** (and context at 18:03:38). It took a third message — the **18:29:39 "OVERRIDE … Acknowledge by starting the work, not another 'holding' status"** — to get work started. This is the #1 crossing problem manifesting as wasted directive latency.

**Severity/impact.** Medium. ~10–25 min of stall per occurrence; happened on the critical-path input-routing task.

**Root cause / fix.** Same as #1 — a pending-directive indicator and reply-sequencing would have prevented the agent from emitting a "holding" status while an unread GO sat in its inbox.

### 5. Messaging an active agent interrupts its work

**Observed.** 13 `idle_notification`s carried `idleReason:"interrupted"`. The cleanest non-reconnect case: lead → wayland-dev status check at **19:18:59** ("Status check — ~40 min on input routing, now idle with no report…"), followed by wayland-dev `idleReason:"interrupted"` at **19:24:59**. A check-in intended to *unblock* the agent instead correlated with interrupting its turn.

**Severity/impact.** Medium, and perverse: it penalizes exactly the supervisory behavior the lead needs (checking on a quiet worker), discouraging healthy oversight.

**Suspected root cause.** Inbound teammate messages are injected as interrupts rather than queued to the agent's next turn boundary.

**Suggested fix.** Deliver lead messages at the recipient's next safe turn boundary by default (queue, don't interrupt), with interruption reserved for an explicit "urgent/preempt" flag.

### 6. No liveness query — lead can only infer "alive" from replies

**Observed.** The lead has no primitive to ask "is agent X alive?" It could only infer from whether messages came back, and it shows: at 19:18:59 it hedged "If wedged, say so and I'll unblock or cycle you like wayland-dig," and Max had to ask the lead directly — **20:07:04 "i think the other teammate died?"** — which the lead could not authoritatively confirm. The **team roster became the de-facto liveness workaround** — an agent absent from it is presumed dead — but that is inference, not a real status query. `TaskList` was called once but does not cover background `Agent` teammates (see #2's ID-namespace gap).

**Severity/impact.** Medium-high; it's the root enabler of #2 and #3's "silent death." Without liveness the lead cannot distinguish *working*, *idle*, *interrupted*, and *dead*.

**Suggested fix.** A `teammate status` / liveness API returning per-agent {alive, last-heartbeat, current-state, last-message-seq} for background agents, plus automatic reaping + notification when a teammate dies.

### 7. Idle-notification volume

**Observed.** 229 `idle_notification`s vs 125 actual work reports (1.83:1). Beyond the reconnect floods (#3), genuine rapid-fire pairs occurred — e.g. gtk4-gpu idle at **18:44:23** then **18:44:47** (24s apart) with no work between; gtk4-gpu also fired 4 idles at the single instant 18:38:45. Each idle notification is delivered to the lead as a turn-triggering event.

**Severity/impact.** Medium. Low individual cost but high aggregate: idle pings outnumber substantive reports nearly 2:1, diluting the lead's attention and inflating context (a contributor to needing 3 compactions).

**Suspected root cause.** Idle is emitted per state-transition with no debounce/coalescing, and "available/idle" is signaled as actively as real progress.

**Suggested fix.** Debounce idle notifications (suppress repeats within a window), coalesce multiple agents' idles into one digest line, and distinguish "idle & awaiting direction" (actionable) from "idle, nothing pending" (suppressible).

---

## Cross-cutting observation: two divergent message wrappers

Incoming cross-session messages appear in **two different formats** in the same session: `<teammate-message teammate_id="…" color="…" summary="…">` (used by the earlier agents and by all idle notifications) and `<agent-message from="…">` (used by the later agents wayland-dev and gtk4-gpu). The second form lacks `summary`/`color`. This is minor but worth flagging: it complicates programmatic handling and suggests two code paths for peer messaging that have drifted; a single canonical envelope (with stable id, seq, sender, summary) would also directly enable the sequencing fix in #1.

---

## What worked well (for balance)

- **The agents' technical output was strong and largely correct.** The fleet delivered real, validated results: M1–M7 Wayland compositor milestones (wl_shm→IOSurface, zero-copy GPU compositing, multi-window), a real libadwaita GNOME Console running GPU-composited on an A10, and a precise one-function ANGLE root-cause for the GTK4-on-A10 ES3 blocker (`DisplayMtl::getMaxSupportedESVersion` gating ES3 on `MTLGPUFamilyApple4`). The friction was purely coordination, not capability.
- **The cooperative `shutdown_request`/`shutdown_approved` handshake works correctly when an agent cooperates** — ddx-integration approved in ~1 min (07:01:48→07:02:49), anglebuild at 09:21:00, wayland-dig at 17:59:42. The gap is only the *absence of an involuntary path* (#2), not a broken graceful path.
- **Agents preserved work across the chaos** — every shutdown handoff confirmed committed artifacts (debs, memories, recipes), so despite the crossing/recovery churn, **no technical work was reported lost**; the cost was time and lead attention, not deliverables.
- The lead's own real-time diagnosis ("our messages kept crossing") and adaptive workarounds (clean-reset re-spawns, explicit OVERRIDE labeling, roster-as-liveness) were reasonable mitigations for primitives that don't yet exist.

**Net:** the platform made a 21-agent, multi-session, ~39-hour build *succeed*, but the operator spent a large share of turns fighting message ordering, un-killable agents, and reconnect artifacts rather than the actual engineering. Fixing #1 (ordered/sequenced delivery), #2 (force-kill + ID resolution), and #3/#6 (idempotent recovery + liveness) would remove most of the observed overhead.

---

## Method / reproducibility

Findings were extracted programmatically from the session JSONL (record types: `user`, `assistant` tool_use blocks, `queue-operation`, `system`, `attachment`). Coordination events were parsed from two message wrappers (`<teammate-message>` and `<agent-message>`), `idle_notification` JSON payloads, `SendMessage`/`Agent`/`TaskStop` tool calls and their results, and `shutdown_request`/`_approved`/`_rejected` exchanges. All counts above are reproducible from the transcript named at the top of this document.
