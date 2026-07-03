# Sub-agent brief checklist

Paste/adapt these guardrails into every `Agent()` prompt spawned for this project. Born from the 2026-07-02 incidents (a publish agent's unrequested ICU bump broke apt; agents flipped the live compositor session; near-miss clobbering libmutter builds).

## The three rules (verbatim into every brief)

1. **No unrequested judgment calls.**
   > Do exactly the task. Do NOT change versions, behavior, or scope beyond it. If you hit a judgment call (a version bump, a "newest-per-package" sweep, a behavior change, a cleanup that touches unrelated things), STOP and FLAG it for approval instead of acting.

2. **Single owner per shared resource.**
   > One agent owns the device compositor session at a time; one owns each build artifact/volume. Do NOT switch the compositor session (`xios-session -d ...`), rebuild an artifact another agent owns, or touch shared files it's editing. If you need a shared resource, request it via the coordinator first.
   - Ownership map (name the owner in the brief): device session; `libmutter`/`procursus-vol-gtk`; `gcc`+gnome stack/`procursus-vol-shell`; the repo (`repo/`, publish scripts); the Xios app (`apps/Xios/`).

3. **Additive by default.**
   > Prefer additive changes. Surface anything destructive (removals, downgrades, overwrites, force-flags) for approval rather than doing it silently.

## Coordinator (main-thread) checklist

- **Before broad/irreversible device ops** (`dist-upgrade`, `fix-broken`, mass installs): the system is fragile until package-reproducible → snapshot (dpkg selections + hand-deployed-file manifest) or flag + offer targeted alternative. A clean `apt-get ... -s` simulation is NOT a safety proof on a hand-patched system.
- **Protect exhaustively:** `apt-mark hold` ALL hand-deployed components, not just the salient one.
- **Max's hard rule:** never remove/downgrade OUR OWN packages on the device — verify 0-remove-of-ours before every device apt action.
- **When >1 agent touches a domain:** name the single owner explicitly; tell the others to stay out; prefer sequencing shared-artifact work through one agent.
- **Device coordination:** agents ping the coordinator before deploying/restarting the session; the coordinator serializes device access.

See memories: `broad-ops-need-snapshot-repro`, `subagent-guardrails`.
