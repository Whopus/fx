import test from "node:test";
import assert from "node:assert/strict";
import { executeAgent } from "../src/notebook.ts";
import { MemoryRuntime } from "../src/memory-runtime.ts";
import type { FxNotebook } from "../src/types.ts";

function notebook(): FxNotebook {
  return {
    version: 1,
    id: "test",
    title: "test",
    cells: [{
      id: "agent",
      type: "agent",
      cells: [{ id: "query-1", type: "query", content: [{ type: "text", text: "first" }] }],
    }],
  };
}

test("execution materializes one Output directly after its Agent", async () => {
  const document = notebook();
  const output = await executeAgent(document, "agent", new MemoryRuntime());
  assert.equal(output.type, "output");
  assert.equal(output.forAgent, "agent");
  assert.equal(output.final, "first");
  assert.equal(document.cells[1], output);
  assert.equal(output.messages?.length, 2);
});

test("continuation retains run id, transcript, events, and prior rounds", async () => {
  const document = notebook();
  const first = await executeAgent(document, "agent", new MemoryRuntime());
  const agent = document.cells[0];
  if (!agent || agent.type !== "agent") throw new Error("missing agent");
  agent.cells.push({ id: "query-2", type: "query", content: [{ type: "text", text: "follow up" }] });
  const output = await executeAgent(document, "agent", new MemoryRuntime(), undefined, { continue: true });
  assert.equal(output.runId, first.runId);
  assert.deepEqual(output.rounds?.map((round) => round.final), ["first", "follow up"]);
  assert.equal(output.final, "follow up");
  assert.ok((output.messages?.length ?? 0) > (first.messages?.length ?? 0));
  assert.equal(document.cells.filter((cell) => cell.type === "output").length, 1);
});

test("one Run assembles every Query into a single request", async () => {
  const document: FxNotebook = {
    version: 1,
    id: "test",
    title: "test",
    cells: [{
      id: "agent",
      type: "agent",
      cells: [
        { id: "query-1", type: "query", content: [{ type: "text", text: "first" }] },
        { id: "query-2", type: "query", content: [{ type: "text", text: "second" }] },
        { id: "query-3", type: "query", content: [{ type: "text", text: "third" }] },
      ],
    }],
  };
  const output = await executeAgent(document, "agent", new MemoryRuntime());
  // Only the last Query is the pending turn, so the run produces one round.
  assert.equal(output.final, "third");
  assert.equal(output.rounds?.length, 1);
  assert.deepEqual(output.rounds?.map((round) => round.queryCellId), ["query-3"]);
  assert.equal(output.events.filter((event) => event.type === "fx/round_start").length, 1);
  // Earlier Queries stay in the assembled request as history, not as rounds.
  const roles = (output.messages ?? []).map((message) => (message as { role: string }).role);
  assert.deepEqual(roles, ["user", "user", "user", "assistant"]);
});
