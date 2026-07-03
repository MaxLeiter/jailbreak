// CLI entry — one-shot turn over the shared daemon. The web console (server.ts)
// wires the same buildJarvis() differently (approvals + events go to the browser).
//
//   bun run src/main.ts "what's in /etc/hosts?"          # uses .env

import { VIA_GATEWAY, buildJarvis } from "./daemon";

async function main() {
  console.error(`  model routing: ${VIA_GATEWAY ? "Vercel AI Gateway" : "Anthropic direct"}`);

  const { session, store } = buildJarvis({
    // Non-interactive CLI: gated ("ask") capabilities auto-deny. Run the console
    // for human-in-the-loop approvals.
    ask: async (req) => {
      console.error(`  [ask] ${req.tool.name}(${req.scope}) — auto-denying in CLI`);
      return false;
    },
  });

  const prior = await store.load("main");
  if (prior) session.restore(prior);

  const prompt =
    process.argv.slice(2).join(" ") ||
    "List the top-level entries of my home directory and tell me what stands out.";
  console.log(`\n> ${prompt}\n`);
  const reply = await session.send(prompt);
  console.log(`\n${reply}\n`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
