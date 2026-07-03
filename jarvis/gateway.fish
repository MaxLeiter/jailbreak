#!/usr/bin/env fish
# Route this shell — including `claude` (Claude Code) and anything using the
# Anthropic SDK — through the Vercel AI Gateway. Reads the key from .env so the
# secret lives in exactly one place.
#
#   source gateway.fish
#   claude            # now billed/observed through the gateway
#
# Undo by opening a new shell (these are exported only for the current session).

set -l dir (dirname (status --current-filename))
if not test -f $dir/.env
    echo "gateway.fish: $dir/.env not found — run `vercel ai-gateway api-keys create` first" >&2
    exit 1
end

for line in (cat $dir/.env)
    string match -q '#*' -- $line; and continue
    set -l kv (string split -m1 = -- $line)
    test (count $kv) -eq 2; or continue
    set -gx $kv[1] $kv[2]
end

# Claude Code checks ANTHROPIC_API_KEY first and uses it if non-empty, so it must
# stay empty for the gateway's ANTHROPIC_AUTH_TOKEN to win.
set -gx ANTHROPIC_API_KEY ""

echo "→ AI Gateway: $ANTHROPIC_BASE_URL (auth: "(string sub -l 8 $ANTHROPIC_AUTH_TOKEN)"…)"
