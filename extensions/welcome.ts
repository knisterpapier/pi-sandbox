/**
 * pi-sandbox glue.
 *
 * The feynman package replaces pi's built-in welcome header (version + key
 * hints) with its own research card, built asynchronously at session start —
 * whoever calls setHeader last wins. This extension restores pi's built-in
 * header after feynman's async build settles, and adds `/sandbox` for the
 * sandbox facts (model, mount, MCP) the entrypoint used to echo
 * before pi's screen paint erased it.
 *
 * Loaded via the `extensions` array in settings.json, which entrypoint.sh
 * maintains. Intentionally imports nothing at runtime: jiti resolves modules
 * relative to this file, and the repo folder has no node_modules of its own.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

function sandboxFacts() {
  const e = process.env;
  let mcp = 0;
  while (e[`PI_MCP_${mcp + 1}_NAME`]) mcp += 1;
  return {
    subdir: e.PI_SANDBOX_SUBDIR || "pi-sandbox",
    host: e.PI_SANDBOX_HOST_PROJECT || "the folder you ran ./run.sh from",
    model: e.PI_MODEL_ID || "default",
    ctx: e.PI_CONTEXT_WINDOW || "128000",
    maxOut: e.PI_MAX_TOKENS || "4096",
    mcp,
  };
}

function topEntries(dir: string): number | null {
  try {
    const { readdirSync } = require("node:fs") as typeof import("node:fs");
    return readdirSync(dir).length;
  } catch {
    return null;
  }
}

export default function (pi: ExtensionAPI) {
  const restoreHeader = (ctx: ExtensionContext) => {
    if (ctx.mode === "tui" && ctx.hasUI) ctx.ui.setHeader(undefined);
  };

  pi.on("session_start", async (_event, ctx) => {
    restoreHeader(ctx);
    // feynman's card lands after an async catalog build; re-restore until its
    // promise chain has settled so pi's own welcome stays on screen.
    for (const ms of [150, 600, 1500, 3000]) setTimeout(() => restoreHeader(ctx), ms);
  });

  pi.registerCommand("sandbox", {
    description: "Show what this sandbox exposes (model, mount, MCP)",
    handler: async (_args, ctx) => {
      const f = sandboxFacts();
      const entries = topEntries(ctx.cwd);
      ctx.ui.notify(
        [
          `model ${f.model} (${f.ctx} ctx, ${f.maxOut} max out) via provider "sandbox"`,
          `${f.mcp} MCP servers · pi packages per PI_PACKAGES`,
          `only mount: ${f.host} → /workspace` +
            (entries !== null ? ` (${entries} top-level entries)` : ""),
          `everything pi can change lives under ${f.subdir}/data/ (gitignored) or /workspace`,
        ].join("\n"),
        "info",
      );
    },
  });
}
