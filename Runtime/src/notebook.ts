import { randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { compileAgent, normalizeNotebook, validateNotebook } from "./compiler.ts";
import type { CuratezNotebook, CuratezRuntime, OutputCell, RunHooks } from "./types.ts";

export async function loadNotebook(path: string): Promise<CuratezNotebook> {
  const value: unknown = normalizeNotebook(JSON.parse(await readFile(path, "utf8")));
  validateNotebook(value);
  return value;
}

export function newNotebook(title = "Untitled Curatez Agent"): CuratezNotebook {
  return {
    version: 1,
    id: randomUUID(),
    title,
    cells: [{
      id: randomUUID(),
      type: "agent",
      name: "Agent 1",
      toolExecution: "parallel",
      cells: [],
    }],
  };
}

export async function saveNotebook(path: string, notebook: CuratezNotebook): Promise<void> {
  validateNotebook(notebook);
  await writeFile(path, `${JSON.stringify(notebook, null, 2)}\n`, "utf8");
}

export async function executeAgent(
  notebook: CuratezNotebook,
  agentId: string,
  runtime: CuratezRuntime,
  hooks?: RunHooks,
  options: { continue?: boolean } = {},
): Promise<OutputCell> {
  const previous = notebook.cells.find(
    (cell): cell is OutputCell => cell.type === "output" && cell.forAgent === agentId,
  );
  const result = await runtime.run(
    compileAgent(notebook, agentId),
    options.continue && previous ? { ...hooks, resume: previous } : hooks,
  );
  const output: OutputCell = {
    id: `${agentId}:output`,
    type: "output",
    forAgent: agentId,
    ...result,
  };
  const existing = notebook.cells.findIndex((cell) => cell.type === "output" && cell.forAgent === agentId);
  if (existing >= 0) notebook.cells[existing] = output;
  else {
    const agentIndex = notebook.cells.findIndex((cell) => cell.id === agentId);
    notebook.cells.splice(agentIndex + 1, 0, output);
  }
  return output;
}
