#!/usr/bin/env node
import { appendFile } from "node:fs/promises";
import { once } from "node:events";
import { resolve } from "node:path";
import { executeAgent, loadNotebook, saveNotebook } from "./notebook.ts";
import { compactStreamEvent } from "./event-stream.ts";
import { loadModelRegistry, resolveModel } from "./model-registry.ts";
import { PiRuntime } from "./pi-runtime.ts";
import { builtinTools } from "./tools.ts";
import type { CuratezEvent } from "./types.ts";

function option(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function usage(): never {
  console.error("curatez-runtime inspect <notebook.json>\ncuratez-runtime run <notebook.json> --agent <cell-id> [--model provider/model] [--continue] [--event-log path] [--event-stream]");
  process.exit(2);
}

async function writeStreamEvent(event: CuratezEvent): Promise<void> {
  if (process.stdout.write(`${JSON.stringify(compactStreamEvent(event))}\n`)) return;
  await once(process.stdout, "drain");
}

const command = process.argv[2];
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
if (!modelSpec?.includes("/")) throw new Error("Set --model provider/model or CURATEZ_MODEL");
const model = resolveModel(registry.models, modelSpec);
if (!model) throw new Error(`Unknown model: ${modelSpec}`);

const controller = new AbortController();
process.once("SIGINT", () => controller.abort());
process.once("SIGTERM", () => controller.abort());
const eventLog = option("--event-log");
const eventStream = process.argv.includes("--event-stream");
const runtime = new PiRuntime({
  model,
  resolveModel: (id) => resolveModel(registry.models, id),
  streamFn: (selected, context, options) => registry.models.streamSimple(
    selected,
    context,
    { ...options, timeoutMs: 60_000 },
  ),
  tools: builtinTools(),
});
const output = await executeAgent(
  notebook,
  agentId,
  runtime,
  {
    signal: controller.signal,
    onEvent: async (event) => {
      if (eventLog) await appendFile(resolve(eventLog), `${JSON.stringify(event)}\n`, "utf8");
      if (eventStream) await writeStreamEvent(event);
      if (event.type === "tool_execution_start") {
        const data = event.data as { toolName?: string };
        process.stderr.write(`tool: ${data.toolName ?? "unknown"}\n`);
      }
    },
  },
  { continue: process.argv.includes("--continue") },
);
await saveNotebook(path, notebook);
if (!eventStream) process.stdout.write(`${output.final}\n`);
if (output.status !== "completed") process.exitCode = 1;
