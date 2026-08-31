import { randomUUID } from "node:crypto";
import type { CompiledRun, CuratezEvent, CuratezRuntime, OutputCell, RunHooks } from "./types.ts";

/** Deterministic protocol runtime used only by tests and offline diagnostics. */
export class MemoryRuntime implements CuratezRuntime {
  async run(
    compiled: CompiledRun,
    hooks: RunHooks = {},
  ): Promise<Omit<OutputCell, "id" | "type" | "forAgent">> {
    const startedAt = hooks.resume?.startedAt ?? new Date().toISOString();
    const events: CuratezEvent[] = [...(hooks.resume?.events ?? [])];
    const push = async (type: string, data: unknown) => {
      const event = { type, time: new Date().toISOString(), data };
      events.push(event);
      await hooks.onEvent?.(event);
    };
    if (!hooks.resume) await push("agent_start", { agent: compiled.agent.id });
    const rounds = [...(hooks.resume?.rounds ?? [])];
    const messages = [...(hooks.resume?.messages ?? [])];
    let final = hooks.resume?.final ?? "";
    const completed = rounds.length;
    for (const [pendingIndex, query] of compiled.queries.slice(completed).entries()) {
      const roundIndex = completed + pendingIndex;
      const roundStartedAt = new Date().toISOString();
      await push("fx/round_start", { round: roundIndex + 1, queryCellId: query.cell.id });
      const queryText = query.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
      messages.push({ role: "user", content: query.content });
      final = queryText;
      await push("message_end", { role: "assistant", content: final, round: roundIndex + 1 });
      messages.push({ role: "assistant", content: [{ type: "text", text: final }] });
      const endedAt = new Date().toISOString();
      rounds.push({ index: roundIndex + 1, queryCellId: query.cell.id, final, startedAt: roundStartedAt, endedAt });
      await push("fx/round_end", { round: roundIndex + 1, queryCellId: query.cell.id });
    }
    if (compiled.queries.length > completed) await push("agent_end", {});
    return {
      runId: hooks.resume?.runId ?? randomUUID(),
      status: "completed",
      runtime: "static-preview",
      final,
      rounds,
      messages,
      events,
      startedAt,
      endedAt: new Date().toISOString(),
    };
  }
}
