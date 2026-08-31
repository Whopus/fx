import type { CompiledRun, ContextCell, CuratezNotebook, OutputCell, QueryPart } from "./types.ts";

function outputContext(cell: ContextCell, outputs: Map<string, OutputCell>): string {
  if (!cell.fromOutput) {
    const parts = [cell.content?.trim() ?? ""];
    for (const attachment of cell.attachments ?? []) {
      if (attachment.mediaType.startsWith("text/")) {
        parts.push(`<attachment name="${attachment.name}" type="${attachment.mediaType}">\n${Buffer.from(attachment.data, "base64").toString("utf8")}\n</attachment>`);
      } else {
        parts.push(`<attachment name="${attachment.name}" type="${attachment.mediaType}" size="${attachment.size}" />`);
      }
    }
    return parts.filter(Boolean).join("\n\n");
  }
  const output = outputs.get(cell.fromOutput);
  if (!output) throw new Error(`Context ${cell.id} references missing Output ${cell.fromOutput}`);
  if (cell.select === "trace") return JSON.stringify(output.events);
  if (cell.select === "all") return JSON.stringify({ final: output.final, events: output.events, usage: output.usage });
  return output.final;
}

export function compileAgent(notebook: CuratezNotebook, agentId: string): CompiledRun {
  const agentIndex = notebook.cells.findIndex((cell) => cell.id === agentId && cell.type === "agent");
  if (agentIndex < 0) throw new Error(`Agent Cell not found: ${agentId}`);
  const agent = notebook.cells[agentIndex];
  if (!agent || agent.type !== "agent") throw new Error(`Cell ${agentId} is not an Agent`);
  const active = agent.cells;
  const outputs = new Map(notebook.cells.filter((cell): cell is OutputCell => cell.type === "output").map((cell) => [cell.id, cell]));
  const queries = active.filter((cell) => cell.type === "query").map((cell) => ({ cell, content: cell.content }));
  const query = queries.flatMap((round) => round.content) as QueryPart[];
  if (!query.some((part) => part.type === "text" ? part.text.trim() : part.data)) throw new Error(`Agent ${agentId} has no Query`);
  return {
    agent,
    system: active.filter((cell) => cell.type === "system"),
    context: active.filter((cell): cell is ContextCell => cell.type === "context").map((cell) => ({ cell, value: outputContext(cell, outputs) })).filter((item) => item.value),
    queries,
    query,
    tools: active.filter((cell) => cell.type === "tool"),
    skills: active.filter((cell) => cell.type === "skill"),
    subagents: active.filter((cell) => cell.type === "subagent"),
  };
}

export function validateNotebook(value: unknown): asserts value is CuratezNotebook {
  if (!value || typeof value !== "object") throw new TypeError("Notebook must be an object");
  const notebook = value as Partial<CuratezNotebook>;
  if (notebook.version !== 1 || typeof notebook.id !== "string" || typeof notebook.title !== "string" || !Array.isArray(notebook.cells)) {
    throw new TypeError("Invalid Curatez runtime notebook header");
  }
  const ids = new Set<string>();
  for (const cell of notebook.cells) {
    if (!cell || typeof cell.id !== "string" || typeof cell.type !== "string") throw new TypeError("Invalid Cell");
    if (ids.has(cell.id)) throw new TypeError(`Duplicate Cell id: ${cell.id}`);
    ids.add(cell.id);
    if (cell.type !== "agent" && cell.type !== "output") {
      throw new TypeError(`Notebook top level only accepts Agent/Output: ${String((cell as { type: unknown }).type)}`);
    }
    if (cell.type === "agent") {
      if (!Array.isArray(cell.cells)) throw new TypeError(`Agent ${cell.id} must contain cells`);
      for (const child of cell.cells) {
        if (!child || typeof child.id !== "string" || !["system", "context", "query", "tool", "skill", "subagent"].includes(child.type)) {
          throw new TypeError(`Invalid child Cell in Agent ${cell.id}`);
        }
        if (ids.has(child.id)) throw new TypeError(`Duplicate Cell id: ${child.id}`);
        ids.add(child.id);
      }
    }
  }
}

/** One-time in-place migration from the early flat prototype to nested Agent Cells. */
export function normalizeNotebook(value: unknown): unknown {
  if (!value || typeof value !== "object" || !Array.isArray((value as { cells?: unknown }).cells)) return value;
  const notebook = value as { cells: Array<Record<string, unknown>> };
  for (const top of notebook.cells) {
    const cells = top.type === "agent" && Array.isArray(top.cells)
      ? top.cells as Array<Record<string, unknown>>
      : [top];
    for (const cell of cells) {
      if (cell.type === "tool" && typeof cell.description !== "string") cell.description = "";
    }
  }
  if (!notebook.cells.some((cell) => ["system", "context", "query", "tool", "skill", "subagent"].includes(String(cell.type)))) {
    return value;
  }
  const next: Array<Record<string, unknown>> = [];
  let pending: Array<Record<string, unknown>> = [];
  for (const cell of notebook.cells) {
    if (["system", "context", "query", "tool", "skill", "subagent"].includes(String(cell.type))) {
      pending.push(cell);
      continue;
    }
    if (cell.type === "agent") {
      next.push({ ...cell, cells: pending });
      pending = [];
      continue;
    }
    next.push(cell);
  }
  notebook.cells = next;
  return value;
}
