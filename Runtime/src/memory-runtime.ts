import { randomUUID } from "node:crypto";
import type { CompiledRun, FxEvent, FxRuntime, OutputCell, RunHooks } from "./types.ts";

/** Deterministic protocol runtime used only by tests and offline diagnostics. */
export class MemoryRuntime implements FxRuntime {
  async run(
    compiled: CompiledRun,
    hooks: RunHooks = {},
  ): Promise<Omit<OutputCell, "id" | "type" | "forAgent">> {
    const startedAt = hooks.resume?.startedAt ?? new Date().toISOString();
    const events: FxEvent[] = [...(hooks.resume?.events ?? [])];
    const push = async (type: string, data: unknown) => {
      const event = { type, time: new Date().toISOString(), data };
      events.push(event);
      await hooks.onEvent?.(event);
    };
    if (!hooks.resume) await push("agent_start", { agent: compiled.agent.id });
    const rounds = [...(hooks.resume?.rounds ?? [])];
    const messages = [...(hooks.resume?.messages ?? [])];
    // Seed earlier Query Cells as user turns on the first run; a resumed run
    // already carries them in the persisted transcript.
    if (!hooks.resume) {
      for (const query of compiled.queries.slice(0, -1)) {
        messages.push({ role: "user", content: query.content });
      }
    }
    let final = hooks.resume?.final ?? "";
    // One Run assembles the notebook into a single request: the last Query Cell
    // is the pending turn, so there is exactly one round per run.
    const pending = compiled.queries.at(-1);
    if (!pending) throw new Error(`Agent ${compiled.agent.id} has no Query`);
    const roundIndex = rounds.length;
    const roundStartedAt = new Date().toISOString();
    await push("fx/round_start", { round: roundIndex + 1, queryCellId: pending.cell.id });
    const queryText = pending.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
    messages.push({ role: "user", content: pending.content });
    final = queryText;
    await push("message_end", { role: "assistant", content: final, round: roundIndex + 1 });
    messages.push({ role: "assistant", content: [{ type: "text", text: final }] });
    const endedAt = new Date().toISOString();
    rounds.push({ index: roundIndex + 1, queryCellId: pending.cell.id, final, startedAt: roundStartedAt, endedAt });
    await push("fx/round_end", { round: roundIndex + 1, queryCellId: pending.cell.id });
    await push("agent_end", {});
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
