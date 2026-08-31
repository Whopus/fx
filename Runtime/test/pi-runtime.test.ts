import test from "node:test";
import assert from "node:assert/strict";
import { createModels } from "@earendil-works/pi-ai";
import { fauxAssistantMessage, fauxProvider, fauxThinking, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { PiRuntime } from "../src/pi-runtime.ts";
import { builtinTools } from "../src/tools.ts";
import type { CompiledRun } from "../src/types.ts";

function base(): CompiledRun {
  return {
    agent: { id: "agent", type: "agent", cells: [] },
    system: [{ id: "system", type: "system", content: "Be concise." }],
    context: [],
    queries: [{
      cell: { id: "query", type: "query", content: [{ type: "text", text: "Run." }] },
      content: [{ type: "text", text: "Run." }],
    }],
    query: [{ type: "text", text: "Run." }],
    tools: [],
    skills: [],
    subagents: [],
  };
}

test("default Agent exposes no tools and Tool items opt in one capability at a time", async () => {
  const faux = fauxProvider({ provider: "faux-tool-selection" });
  const models = createModels();
  models.setProvider(faux.provider);
  faux.setResponses([
    (context) => {
      assert.deepEqual(context.tools?.map((tool) => tool.name) ?? [], []);
      return fauxAssistantMessage("no tools");
    },
    (context) => {
      assert.deepEqual(context.tools?.map((tool) => tool.name) ?? [], ["read"]);
      return fauxAssistantMessage("read only");
    },
  ]);
  const compiled = base();
  const runtime = new PiRuntime({
    model: faux.getModel(),
    streamFn: models.streamSimple.bind(models),
    tools: builtinTools(),
  });

  assert.equal((await runtime.run(compiled)).final, "no tools");
  compiled.tools.push({ id: "read-tool", type: "tool", name: "read", description: "Read files" });
  assert.equal((await runtime.run(compiled)).final, "read only");
});

test("preserves the pi-agent loop and progressively loads a Skill", async () => {
  const faux = fauxProvider();
  const models = createModels();
  models.setProvider(faux.provider);
  faux.setResponses([
    fauxAssistantMessage([
      fauxThinking("I should load the relevant skill."),
      fauxToolCall("load_skill", { name: "pattern" }, { id: "skill-call" }),
    ], { stopReason: "toolUse" }),
    fauxAssistantMessage("skill loaded"),
  ]);
  const compiled = base();
  compiled.skills.push({ id: "skill", type: "skill", name: "pattern", description: "A pattern", instructions: "FULL SKILL" });
  const output = await new PiRuntime({ model: faux.getModel(), streamFn: models.streamSimple.bind(models) }).run(compiled);
  assert.equal(output.status, "completed");
  assert.equal(output.final, "skill loaded");
  assert.ok(output.events.some((event) => event.type === "tool_execution_start"));
  assert.ok(output.events.some((event) => event.type === "tool_execution_end"));
  assert.deepEqual(output.rounds?.[0]?.steps?.map((step) => step.type), ["reasoning", "tool-call", "tool-result"]);
  assert.equal(output.rounds?.[0]?.steps?.[0]?.type === "reasoning" && output.rounds[0].steps[0].text, "I should load the relevant skill.");
  assert.ok((output.messages?.length ?? 0) >= 4);
});

test("resumes persisted messages for a Query appended after Output", async () => {
  const faux = fauxProvider({ provider: "faux-rounds" });
  const models = createModels();
  models.setProvider(faux.provider);
  faux.setResponses([fauxAssistantMessage("first answer"), fauxAssistantMessage("second answer")]);
  const compiled = base();
  const runtime = new PiRuntime({ model: faux.getModel(), streamFn: models.streamSimple.bind(models) });
  const first = await runtime.run(compiled);
  compiled.queries.push({
    cell: { id: "query-2", type: "query", content: [{ type: "text", text: "Follow up." }] },
    content: [{ type: "text", text: "Follow up." }],
  });
  const output = await runtime.run(compiled, {
    resume: { id: "output", type: "output", forAgent: "agent", ...first },
  });
  assert.equal(output.status, "completed");
  assert.deepEqual(output.rounds?.map((round) => round.final), ["first answer", "second answer"]);
  assert.equal(output.final, "second answer");
  assert.equal(output.events.filter((event) => event.type.endsWith("round_start")).length, 2);
  assert.equal(output.runId, first.runId);
  assert.ok((output.messages?.length ?? 0) > (first.messages?.length ?? 0));
});

test("Subagent registers an isolated child Agent and links complete child events", async () => {
  const faux = fauxProvider({ provider: "faux-subagent" });
  const models = createModels();
  models.setProvider(faux.provider);
  faux.setResponses([
    (context) => {
      assert.deepEqual(context.tools?.map((tool) => tool.name) ?? [], ["subagent"]);
      return fauxAssistantMessage(fauxToolCall("subagent", { agent: "scout", task: "find facts" }, { id: "delegate-1" }), { stopReason: "toolUse" });
    },
    fauxAssistantMessage("child facts"),
    fauxAssistantMessage("parent synthesis"),
  ]);
  const compiled = base();
  compiled.subagents.push({ id: "subagent", type: "subagent", name: "scout", description: "Investigate", system: "Return facts." });
  const output = await new PiRuntime({ model: faux.getModel(), streamFn: models.streamSimple.bind(models) }).run(compiled);
  assert.equal(output.final, "parent synthesis");
  assert.ok(output.events.some((event) => event.type.startsWith("subagent/") && event.parentToolCallId === "delegate-1"));
});

test("fork copies completed parent messages but excludes the pending delegation call", async () => {
  const faux = fauxProvider({ provider: "faux-fork" });
  const models = createModels();
  models.setProvider(faux.provider);
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("subagent", { agent: "scout", task: "child task" }, { id: "fork-call" }), { stopReason: "toolUse" }),
    (context) => {
      assert.deepEqual(context.messages.map((message) => message.role), ["user", "user"]);
      assert.match(JSON.stringify(context.messages), /Run\./);
      assert.doesNotMatch(JSON.stringify(context.messages), /fork-call/);
      return fauxAssistantMessage("forked child");
    },
    fauxAssistantMessage("fork complete"),
  ]);
  const compiled = base();
  compiled.subagents.push({
    id: "subagent",
    type: "subagent",
    name: "scout",
    description: "Investigate",
    system: "Return facts.",
    fork: true,
  });
  const output = await new PiRuntime({ model: faux.getModel(), streamFn: models.streamSimple.bind(models) }).run(compiled);
  assert.equal(output.final, "fork complete");
});
