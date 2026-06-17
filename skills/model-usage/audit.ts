#!/usr/bin/env bun
/**
 * model-usage — audit Claude Code token usage from local session transcripts,
 * and (optionally) apply token-saving config changes.
 *
 * Hierarchy: account → repo → project (cwd) → session (.jsonl) → turn.
 * Attribution keys off the recorded `cwd`/`gitBranch`/`sessionId` inside each
 * session — lossless, unlike the sanitized projects/<dir> name. Account is joined
 * from ~/.claude/session-accounts.jsonl (written by the stamp-account SessionStart
 * hook; sessions before that hook show as "(pre-hook)"). Reads only model names,
 * token counts, cwd, branch, sessionId; never emits conversation content.
 *
 *   bun run audit.ts                 # model split + recommendations
 *   bun run audit.ts --by-repo       # collapse worktrees → repo (via cwd)
 *   bun run audit.ts --by-project    # per project (cwd)
 *   bun run audit.ts --by-account    # per Claude account (needs the stamp hook)
 *   bun run audit.ts --days=30       # only records <=30d old
 *   bun run audit.ts --json          # machine-readable (repos + projects + accounts)
 *   bun run audit.ts --apply         # write recommended settings (caller must confirm first)
 *
 * The $ column is a directional ESTIMATE using public list prices, not your
 * actual subscription billing. Use it for relative share, not as a bill.
 */
import { z } from "zod";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";

// ---------- args ----------
const argv = process.argv.slice(2);
const has = (f: string) => argv.includes(f);
const APPLY = has("--apply");
const JSON_OUT = has("--json");
const BY_PROJECT = has("--by-project");
const BY_REPO = has("--by-repo");
const BY_ACCOUNT = has("--by-account");
const daysArg = argv.find((a) => a.startsWith("--days="));
const DAYS = daysArg ? Number(daysArg.split("=")[1]) : null;

const HOME = homedir();
const CONFIG_DIR = process.env.CLAUDE_CONFIG_DIR || join(HOME, ".config", "claude");
const PROJECTS = join(CONFIG_DIR, "projects");
const SETTINGS = join(HOME, ".claude", "settings.json");
const ACCOUNTS_LOG = join(HOME, ".claude", "session-accounts.jsonl");

// ---------- zod contracts ----------
const Usage = z.object({
  input_tokens: z.number().optional(),
  output_tokens: z.number().optional(),
  cache_read_input_tokens: z.number().optional(),
  cache_creation_input_tokens: z.number().optional(),
});
const AssistantRecord = z.object({
  type: z.literal("assistant"),
  timestamp: z.string().optional(),
  message: z.object({ model: z.string(), usage: Usage }),
});

const SettingsPatch = z.object({
  model: z.string().optional(),
  effortLevel: z.enum(["low", "medium", "high", "xhigh"]).optional(),
  autoCompactEnabled: z.boolean().optional(),
  skillListingMaxDescChars: z.number().optional(),
  fastModePerSessionOptIn: z.boolean().optional(),
  env: z.record(z.string()).optional(),
});
type SettingsPatch = z.infer<typeof SettingsPatch>;

// ---------- cost model ($/Mtok: [in, out, cacheRead, cacheWrite]) ----------
const RATES: Record<string, [number, number, number, number]> = {
  opus: [15, 75, 1.5, 18.75],
  sonnet: [3, 15, 0.3, 3.75],
  haiku: [1, 5, 0.1, 1.25],
  fable: [5, 25, 0.5, 6.25],
};
const rateFor = (m: string): [number, number, number, number] => {
  for (const k of Object.keys(RATES)) if (m.includes(k)) return RATES[k];
  return [0, 0, 0, 0];
};

// Repo from a real cwd: …/worktrees/<repo>[.git]/<wt> → <repo>; else crawl up to
// the live git root; else "(unknown)". Lossless because cwd is the true path.
function gitTop(dir: string): string | null {
  try {
    const top = execFileSync("git", ["-C", dir, "rev-parse", "--show-toplevel"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return top ? top.split("/").pop()!.replace(/\.git$/, "") : null;
  } catch { return null; }
}
const repoCache = new Map<string, string>();
function repoFromCwd(cwd: string): string {
  if (!cwd.includes("/")) return "(unknown)";
  const cached = repoCache.get(cwd);
  if (cached) return cached;
  const base = cwd.split("/.claude/worktrees/")[0]; // agent worktrees nest here
  let repo: string;
  const m = base.match(/\/wt\/worktrees\/([^/]+?)(?:\.git)?(?:\/|$)/); // canonical wt path
  if (m) repo = m[1];
  else if (existsSync(base) && gitTop(base)) repo = gitTop(base)!; // crawl up to git root
  else repo = "(unknown)";
  repoCache.set(cwd, repo);
  return repo;
}
const shortCwd = (cwd: string): string =>
  (cwd.startsWith(HOME) ? "~" + cwd.slice(HOME.length) : cwd)
    .replace(/^~\/\.local\/state\/wt\/worktrees\//, "wt:");

// ---------- account map (session_id → account), from the stamp-account hook ----------
const accountMap = new Map<string, string>();
try {
  for (const line of (await readFile(ACCOUNTS_LOG, "utf8")).split("\n")) {
    if (!line || line[0] !== "{") continue;
    try { const o = JSON.parse(line); if (o.session_id && o.account) accountMap.set(o.session_id, o.account); } catch {}
  }
} catch { /* no log yet — every session is "(pre-hook)" */ }

// ---------- aggregate ----------
type Row = { in: number; out: number; cr: number; cw: number; cost: number; n: number };
type Grp = { out: number; turns: number; opusOut: number; cost: number; sessions: number };
const tally = new Map<string, Row>();
const byProject = new Map<string, Grp>();
const byRepo = new Map<string, Grp>();
const byAccount = new Map<string, Grp>();
const cutoff = DAYS ? Date.now() - DAYS * 86_400_000 : null;

const addGrp = (map: Map<string, Grp>, key: string, out: number, cost: number, opus: boolean, newSession: boolean) => {
  const g = map.get(key) ?? { out: 0, turns: 0, opusOut: 0, cost: 0, sessions: 0 };
  g.out += out; g.turns++; g.cost += cost; if (opus) g.opusOut += out; if (newSession) g.sessions++;
  map.set(key, g);
};

let files = 0;
let parsedRecords = 0;
let skippedLines = 0;

let entries: string[] = [];
try {
  entries = (await readdir(PROJECTS, { recursive: true })) as string[];
} catch {
  console.error(`No transcripts found at ${PROJECTS}`);
  process.exit(1);
}

for (const rel of entries) {
  if (!rel.endsWith(".jsonl")) continue;
  files++;
  let text = "";
  try {
    text = await readFile(join(PROJECTS, rel), "utf8");
  } catch {
    continue;
  }
  const objs: any[] = [];
  for (const line of text.split("\n")) {
    if (!line || line[0] !== "{") continue;
    try { objs.push(JSON.parse(line)); } catch { skippedLines++; }
  }
  let cwd = "", sid = "";
  for (const o of objs) {
    if (!cwd && o.cwd) cwd = o.cwd;
    if (!sid && o.sessionId) sid = o.sessionId;
    if (cwd && sid) break;
  }
  const project = cwd || `(dir:${rel.split("/")[0] || "root"})`;
  const repo = repoFromCwd(project);
  const account = (sid && accountMap.get(sid)) || "(pre-hook)";
  let first = true;
  for (const o of objs) {
    if (o.type !== "assistant") continue;
    const r = AssistantRecord.safeParse(o);
    if (!r.success) continue;
    if (cutoff && r.data.timestamp) {
      const t = Date.parse(r.data.timestamp);
      if (!Number.isNaN(t) && t < cutoff) continue;
    }
    parsedRecords++;
    const m = r.data.message.model;
    const u = r.data.message.usage;
    const inp = u.input_tokens ?? 0;
    const out = u.output_tokens ?? 0;
    const cr = u.cache_read_input_tokens ?? 0;
    const cw = u.cache_creation_input_tokens ?? 0;
    const [ri, ro, rcr, rcw] = rateFor(m);
    const cost = (inp * ri + out * ro + cr * rcr + cw * rcw) / 1e6;
    const cur = tally.get(m) ?? { in: 0, out: 0, cr: 0, cw: 0, cost: 0, n: 0 };
    cur.in += inp; cur.out += out; cur.cr += cr; cur.cw += cw; cur.cost += cost; cur.n++;
    tally.set(m, cur);
    const opus = m.includes("opus");
    addGrp(byProject, project, out, cost, opus, first);
    addGrp(byRepo, repo, out, cost, opus, first);
    addGrp(byAccount, account, out, cost, opus, first);
    first = false;
  }
}

const rows = [...tally.entries()].sort((a, b) => b[1].cost - a[1].cost);
const totalCost = rows.reduce((s, [, r]) => s + r.cost, 0) || 1;
const totalOut = rows.reduce((s, [, r]) => s + r.out, 0);
const opusCost = rows.filter(([m]) => m.includes("opus")).reduce((s, [, r]) => s + r.cost, 0);
const opusSharePct = (100 * opusCost) / totalCost;

const rollup = (map: Map<string, Grp>, label: string) =>
  [...map.entries()]
    .map(([k, v]) => ({ key: k, label, ...v, opusPct: v.out ? (100 * v.opusOut) / v.out : 0 }))
    .sort((a, b) => b.cost - a.cost);
const projects = rollup(byProject, "project").map((p) => ({ ...p, display: p.key.startsWith("(dir:") ? p.key : shortCwd(p.key) }));
const repos = rollup(byRepo, "repo");
const accounts = rollup(byAccount, "account");

// ---------- recommendation ----------
let current: Record<string, unknown> = {};
try {
  current = JSON.parse(await readFile(SETTINGS, "utf8"));
} catch { /* file may not exist yet */ }

const recommend: SettingsPatch = {};
if (opusSharePct > 50 && current.model !== "sonnet") recommend.model = "sonnet";
if (current.effortLevel === undefined) recommend.effortLevel = "medium";
if (current.autoCompactEnabled === undefined) recommend.autoCompactEnabled = true;
if (current.skillListingMaxDescChars === undefined) recommend.skillListingMaxDescChars = 256;
if (current.fastModePerSessionOptIn === undefined) recommend.fastModePerSessionOptIn = true;
const curEnv = (current.env ?? {}) as Record<string, string>;
const envWant: Record<string, string> = {
  CLAUDE_CODE_SUBAGENT_MODEL: "claude-haiku-4-5-20251001",
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "70",
};
const envPatch: Record<string, string> = {};
for (const [k, v] of Object.entries(envWant)) if (curEnv[k] !== v) envPatch[k] = v;
if (Object.keys(envPatch).length) recommend.env = envPatch;

const patch = SettingsPatch.parse(recommend);
const hasPatch = Object.keys(patch).length > 0;

// ---------- output ----------
const slim = (arr: any[], keyName: string) => arr.slice(0, 25).map((p) => ({
  [keyName]: p.display ?? p.key, sessions: p.sessions, turns: p.turns, outM: +(p.out / 1e6).toFixed(2),
  estSpend: +p.cost.toFixed(2), spendPct: +((100 * p.cost) / totalCost).toFixed(1), opusPct: +p.opusPct.toFixed(1),
}));

if (JSON_OUT) {
  console.log(JSON.stringify({
    window: DAYS ? `${DAYS}d` : "all-retained",
    configDir: CONFIG_DIR,
    sessions: files, records: parsedRecords, skippedLines, accountsKnown: accountMap.size,
    totals: { outputTokens: totalOut, estSpend: Number(totalCost.toFixed(2)), opusSharePct: Number(opusSharePct.toFixed(1)) },
    models: Object.fromEntries(rows.map(([m, r]) => [m, {
      inM: +(r.in / 1e6).toFixed(2), outM: +(r.out / 1e6).toFixed(2),
      cacheReadM: +(r.cr / 1e6).toFixed(2), estSpend: +r.cost.toFixed(2),
      spendPct: +((100 * r.cost) / totalCost).toFixed(1), turns: r.n,
    }])),
    topAccounts: slim(accounts, "account"),
    topRepos: slim(repos, "repo"),
    topProjects: slim(projects, "project"),
    recommend: patch,
  }, null, 2));
} else {
  const pad = (s: string, n: number) => (s.length > n ? "…" + s.slice(-(n - 1)) : s.padEnd(n));
  const num = (x: number, n: number) => x.toFixed(2).padStart(n);
  const int = (x: number, n: number) => String(x).padStart(n);
  const table = (title: string, arr: any[], keyW: number, keyOf: (p: any) => string, limit = 15) => {
    console.log(title);
    console.log(`${pad("", keyW)}${"sess".padStart(6)}${"turns".padStart(8)}${"out(M)".padStart(9)}${"opus%".padStart(7)}${"%spend".padStart(8)}`);
    for (const p of arr.slice(0, limit)) {
      console.log(`${pad(keyOf(p), keyW)}${int(p.sessions, 6)}${int(p.turns, 8)}${num(p.out / 1e6, 9)}${num(p.opusPct, 7)}${num((100 * p.cost) / totalCost, 8)}`);
    }
    console.log("");
  };

  console.log(`\nClaude model usage — ${DAYS ? `last ${DAYS}d` : "all retained transcripts"}  (${files} sessions, ${parsedRecords.toLocaleString()} turns)`);
  console.log(`source: ${PROJECTS}\n`);
  console.log(`${pad("model", 30)}${"in(M)".padStart(9)}${"out(M)".padStart(9)}${"cacheR(M)".padStart(11)}${"$est".padStart(11)}${"%spend".padStart(8)}`);
  for (const [m, r] of rows) {
    console.log(`${pad(m, 30)}${num(r.in / 1e6, 9)}${num(r.out / 1e6, 9)}${num(r.cr / 1e6, 11)}${num(r.cost, 11)}${num((100 * r.cost) / totalCost, 8)}`);
  }
  console.log(`${"-".repeat(78)}`);
  console.log(`TOTAL out ${(totalOut / 1e6).toFixed(1)}M tok   est $${totalCost.toFixed(2)} (list-price estimate, not your bill)`);
  console.log(`OPUS combined spend share: ${opusSharePct.toFixed(1)}%\n`);

  if (BY_ACCOUNT) table(`By account — ${accounts.length} (joined from ${accountMap.size} stamped sessions):`, accounts, 36, (p) => p.key);
  if (BY_REPO) table(`By repo — ${repos.length} repos (worktrees collapsed via cwd), top 15:`, repos, 28, (p) => p.key);
  if (BY_PROJECT) table(`By project — top 15 of ${projects.length} (cwd):`, projects, 46, (p) => p.display);

  if (!hasPatch) {
    console.log("✓ Config already matches token-saving recommendations. Nothing to change.\n");
  } else {
    console.log("Recommended config changes (writes to ~/.claude/settings.json):");
    console.log(JSON.stringify(patch, null, 2));
    console.log(APPLY ? "\nApplying…" : "\nRe-run with --apply to write these (caller should confirm with the user first).\n");
  }
}

// ---------- apply ----------
if (APPLY && hasPatch) {
  const merged: Record<string, unknown> = { ...current };
  for (const [k, v] of Object.entries(patch)) {
    if (k === "env") merged.env = { ...(current.env as object ?? {}), ...(v as object) };
    else merged[k] = v;
  }
  await writeFile(SETTINGS, JSON.stringify(merged, null, 2) + "\n");
  console.log(`✓ wrote ${SETTINGS}`);
  if (patch.model === "sonnet") {
    console.log("NOTE: a model saved via /model lives in ~/.claude.json (runtime) and may override settings.json.");
    console.log("      Run  /model → Sonnet 4.6  once to align it. Escalate to Opus 4.8 (200k, not 1M) on demand.");
  }
  console.log("To make this permanent in your nix setup, copy these keys into the ai-home Claude settings, then `prx home update`.");
}
