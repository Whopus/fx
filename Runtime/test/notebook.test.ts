import test from "node:test";
import assert from "node:assert/strict";
import { executeAgent } from "../src/notebook.ts";
import { MemoryRuntime } from "../src/memory-runtime.ts";
import type { CuratezNotebook } from "../src/types.ts";

function notebook(): CuratezNotebook {
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
