import test from "node:test";
import assert from "node:assert/strict";
import { compactStreamEvent } from "../src/event-stream.ts";

test("live message events retain deltas without repeating the full partial message", () => {
  const event = compactStreamEvent({
    type: "message_update",
    time: "2026-08-30T00:00:00.000Z",
    data: {
      type: "message_update",
      message: { role: "assistant", content: [{ type: "text", text: "an increasingly long response" }] },
      assistantMessageEvent: {
        type: "text_delta",
        contentIndex: 0,
        delta: " response",
        partial: { role: "assistant", content: [{ type: "text", text: "an increasingly long response" }] },
      },
    },
  });

  assert.deepEqual(event.data, {
    type: "message_update",
    assistantMessageEvent: {
      type: "text_delta",
      contentIndex: 0,
      delta: " response",
    },
  });
  assert.doesNotMatch(JSON.stringify(event), /increasingly long/);
});

test("tool events pass through unchanged for complete call and result rendering", () => {
  const event = {
    type: "tool_execution_end",
    time: "2026-08-30T00:00:01.000Z",
    data: { toolCallId: "call-1", toolName: "echo", result: { content: [{ type: "text", text: "done" }] } },
  };
  assert.deepEqual(compactStreamEvent(event), event);
});
