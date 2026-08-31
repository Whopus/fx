import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { builtinTools, createJustOneAPISearchTool } from "../src/tools.ts";

function text(result: { content: Array<{ type: string; text?: string }> }): string {
  return result.content.filter((part) => part.type === "text").map((part) => part.text ?? "").join("\n");
}

test("coding tools bind pi implementations to the current Collection", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "curatez-tools-"));
  try {
    const tools = builtinTools(cwd);
    assert.deepEqual(
      tools.map((tool) => tool.name),
      ["echo", "read", "edit", "bash", "write", "search"],
    );

    const write = tools.find((tool) => tool.name === "write");
    const read = tools.find((tool) => tool.name === "read");
    const edit = tools.find((tool) => tool.name === "edit");
    const bash = tools.find((tool) => tool.name === "bash");
    assert.ok(write && read && edit && bash);

    await write.execute("write-1", { path: "note.txt", content: "hello\n" }, undefined);
    const readResult = await read.execute("read-1", { path: "note.txt" }, undefined);
    assert.match(text(readResult), /hello/);

    const editResult = await edit.execute("edit-1", {
      path: "note.txt",
      edits: [{ oldText: "hello", newText: "curatez" }],
    }, undefined);
    assert.match(text(editResult), /Successfully replaced 1 block/);
    assert.equal(await readFile(join(cwd, "note.txt"), "utf8"), "curatez\n");

    const bashResult = await bash.execute("bash-1", { command: "printf tool-ready" }, undefined);
    assert.match(text(bashResult), /tool-ready/);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
});

test("search calls one JustOneAPI endpoint without exposing the API Key as a parameter", async () => {
  let requestBody: any;
  let authorization = "";
  const fetchImpl = (async (_input: string | URL | Request, init?: RequestInit) => {
    authorization = new Headers(init?.headers).get("Authorization") ?? "";
    requestBody = JSON.parse(String(init?.body));
    return new Response([
      "event: message",
      `data: ${JSON.stringify({
        result: {
          content: [{ type: "text", text: JSON.stringify({ success: true, code: 0, data: { items: [1] } }) }],
          structuredContent: { success: true, code: 0, data: { items: [1] } },
          isError: false,
        },
        jsonrpc: "2.0",
        id: requestBody.id,
      })}`,
      "",
    ].join("\n"), { status: 200, headers: { "Content-Type": "text/event-stream" } });
  }) as typeof fetch;
  const search = createJustOneAPISearchTool({ token: "test-token", fetchImpl });

  const result = await search.execute("search-1", {
    endpoint_id: "xiaohongshu.search_note_v4",
    params: { keyword: "咖啡" },
  }, undefined);

  assert.equal(authorization, "Bearer test-token");
  assert.equal(requestBody.method, "tools/call");
  assert.equal(requestBody.params.name, "call_endpoint");
  assert.deepEqual(requestBody.params.arguments, {
    endpoint_id: "xiaohongshu.search_note_v4",
    params: { keyword: "咖啡" },
  });
  assert.match(text(result), /"items": \[/);
});
