#!/usr/bin/env node
import { once } from "node:events";
import { createWriteStream } from "node:fs";
import { resolve } from "node:path";
import { executeAgent, loadNotebook, saveNotebook } from "./notebook.ts";
import { compactStreamEvent } from "./event-stream.ts";
import { buildCatalog, loadExtensionRegistry, mergeTools } from "./extensions.ts";
import { loadModelRegistry, resolveModel } from "./model-registry.ts";
import { PiRuntime } from "./pi-runtime.ts";
import { builtinTools } from "./tools.ts";
import type { FxEvent } from "./types.ts";

function option(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function usage(): never {
  console.error(
    "fx-runtime inspect <notebook.json>\n" +
    "fx-runtime catalog [--project-dir <dir>] [--json]\n" +
    "fx-runtime run <notebook.json> --agent <cell-id> [--model provider/model] [--continue] [--event-log path] [--event-stream]",
  );
  process.exit(2);
}

async function writeStreamEvent(event: FxEvent): Promise<void> {
  if (process.stdout.write(`${JSON.stringify(compactStreamEvent(event))}\n`)) return;
  await once(process.stdout, "drain");
}

const command = process.argv[2];

// Catalog discovery does not need a notebook: the Swift Tool/Skill/Subagent
// pickers load it before any Session exists.
if (command === "catalog") {
  const projectDir = resolve(option("--project-dir") ?? process.cwd());
  const registry = await loadExtensionRegistry({ projectDir });
  const catalog = buildCatalog(projectDir, builtinTools(projectDir), registry);
  process.stdout.write(`${JSON.stringify(catalog, null, 2)}\n`);
  process.exit(0);
}

const file = process.argv[3];
if (!command || !file) usage();
const path = resolve(file);
const notebook = await loadNotebook(path);
if (command === "inspect") {
  for (const cell of notebook.cells) {
    console.log(`${cell.type.toUpperCase().padEnd(8)} ${cell.id}`);
    if (cell.type === "agent") {
      for (const child of cell.cells) console.log(`  ${child.type.toUpperCase().padEnd(8)} ${child.id}`);
    }
  }
  process.exit(0);
}
if (command !== "run") usage();
const agentId = option("--agent");
if (!agentId) usage();

const registry = await loadModelRegistry();
const modelSpec = option("--model") ?? registry.defaultModel;
if (!modelSpec?.includes("/")) throw new Error("Set --model provider/model or FX_MODEL");
const model = resolveModel(registry.models, modelSpec);
if (!model) throw new Error(`Unknown model: ${modelSpec}`);

// A broken extension file must not abort the run; the missing-name check below
// still reports a Tool Cell that references a tool the failed file never
// registered.
const cwd = process.cwd();
const projectDir = resolve(option("--project-dir") ?? cwd);
const extensions = await loadExtensionRegistry({ projectDir, cwd });
for (const diagnostic of extensions.diagnostics) {
  process.stderr.write(`extension: ${diagnostic.file}: ${diagnostic.message}\n`);
}

const controller = new AbortController();
process.once("SIGINT", () => controller.abort());
process.once("SIGTERM", () => controller.abort());
const eventLog = option("--event-log");
const eventStream = process.argv.includes("--event-stream");
const eventLogStream = eventLog ? createWriteStream(resolve(eventLog), { flags: "a", encoding: "utf8" }) : undefined;

async function writeEventLog(event: FxEvent): Promise<void> {
  if (!eventLogStream) return;
  if (eventLogStream.write(`${JSON.stringify(event)}\n`)) return;
  await once(eventLogStream, "drain");
}

async function closeEventLog(): Promise<void> {
  if (!eventLogStream) return;
  eventLogStream.end();
  await once(eventLogStream, "finish");
}

const runtime = new PiRuntime({
  model,
  resolveModel: (id) => resolveModel(registry.models, id),
  streamFn: (selected, context, options) => registry.models.streamSimple(
    selected,
    context,
    { ...options, timeoutMs: 60_000 },
  ),
  tools: mergeTools(builtinTools(cwd), extensions.tools),
  skills: extensions.skills,
  subagents: extensions.subagents,
});
const output = await executeAgent(
  notebook,
  agentId,
  runtime,
  {
    signal: controller.signal,
    onEvent: async (event) => {
      await writeEventLog(event);
      if (eventStream) await writeStreamEvent(event);
      if (event.type === "tool_execution_start") {
        const data = event.data as { toolName?: string };
        process.stderr.write(`tool: ${data.toolName ?? "unknown"}\n`);
      }
    },
  },
  { continue: process.argv.includes("--continue") },
).finally(closeEventLog);
await saveNotebook(path, notebook);
if (!eventStream) process.stdout.write(`${output.final}\n`);
if (output.status !== "completed") process.exitCode = 1;
