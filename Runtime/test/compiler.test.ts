import test from "node:test";
import assert from "node:assert/strict";
import { compileAgent, normalizeNotebook, validateNotebook } from "../src/compiler.ts";
import type { CuratezNotebook, OutputCell } from "../src/types.ts";

function notebook(): CuratezNotebook {
  return {
    version: 1,
    id: "test",
    title: "test",
    cells: [{
      id: "a1",
      type: "agent",
      cells: [
        { id: "s1", type: "system", content: "system one" },
        { id: "c1", type: "context", content: "context one" },
        { id: "t1", type: "tool", name: "echo", description: "Echo text" },
        { id: "k1", type: "skill", name: "review", description: "review", instructions: "review carefully" },
        { id: "s2", type: "subagent", name: "scout", description: "scout", system: "find facts" },
        { id: "q1", type: "query", content: [{ type: "text", text: "hello" }] },
      ],
    }],
  };
}

test("declaration Cells compile into one Agent execution unit", () => {
  const run = compileAgent(notebook(), "a1");
  assert.equal(run.system.length, 1);
  assert.equal(run.context[0]?.value, "context one");
  assert.deepEqual(run.tools.map((cell) => cell.name), ["echo"]);
  assert.equal(run.tools[0]?.description, "Echo text");
  assert.deepEqual(run.skills.map((cell) => cell.name), ["review"]);
  assert.deepEqual(run.subagents.map((cell) => cell.name), ["scout"]);
  assert.equal(run.query[0]?.type, "text");
});

test("multimodal Context compiles text attachments and image metadata", () => {
  const document = notebook();
  const agent = document.cells[0];
  assert.equal(agent?.type, "agent");
  if (!agent || agent.type !== "agent") throw new Error("missing agent");
  const context = agent.cells.find((cell) => cell.type === "context");
  if (!context || context.type !== "context") throw new Error("missing context");
  context.attachments = [
    { id: "note", name: "note.md", mediaType: "text/markdown", data: Buffer.from("attached fact").toString("base64"), size: 13 },
    { id: "image", name: "diagram.png", mediaType: "image/png", data: "image-data", size: 10 },
  ];
  const value = compileAgent(document, "a1").context[0]?.value ?? "";
  assert.match(value, /attached fact/);
  assert.match(value, /diagram\.png/);
});

test("Context can reference a previous Output", () => {
  const document = notebook();
  const output: OutputCell = {
    id: "old-output",
    type: "output",
    forAgent: "old",
    runId: "run",
    status: "completed",
    final: "known fact",
    events: [],
    startedAt: "x",
    endedAt: "y",
  };
  document.cells = [output, {
    id: "a2",
    type: "agent",
    cells: [
      { id: "c2", type: "context", fromOutput: "old-output", select: "final" },
      { id: "q2", type: "query", content: [{ type: "text", text: "continue" }] },
    ],
  }];
  assert.equal(compileAgent(document, "a2").context[0]?.value, "known fact");
});

test("flat prototype notebooks normalize without losing declaration order", () => {
  const flat: unknown = {
    version: 1,
    id: "flat",
    title: "flat",
    cells: [
      { id: "system", type: "system", content: "system" },
      { id: "tool", type: "tool", name: "echo" },
      { id: "query", type: "query", content: [{ type: "text", text: "hello" }] },
      { id: "agent", type: "agent", cells: [] },
    ],
  };
  const normalized = normalizeNotebook(flat);
  validateNotebook(normalized);
  const agent = normalized.cells[0];
  assert.equal(agent?.type, "agent");
  if (!agent || agent.type !== "agent") throw new Error("missing normalized agent");
  assert.deepEqual(agent.cells.map((cell) => cell.type), ["system", "tool", "query"]);
  const tool = agent.cells.find((cell) => cell.type === "tool");
  assert.equal(tool?.type === "tool" && tool.description, "");
});
