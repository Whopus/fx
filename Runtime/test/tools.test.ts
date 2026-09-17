import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { getEventListeners } from "node:events";
import { builtinTools, createJustOneAPISearchTool } from "../src/tools.ts";

function text(result: { content: Array<{ type: string; text?: string }> }): string {
  return result.content.filter((part) => part.type === "text").map((part) => part.text ?? "").join("\n");
}

test("cancelled searches do not fetch and in-flight searches release abort listeners", async () => {
  const controller = new AbortController();
  controller.abort();
  let fetched = false;
  const search = createJustOneAPISearchTool({
    token: "test-token",
    fetchImpl: (async () => { fetched = true; throw new Error("unexpected fetch"); }) as typeof fetch,
  });
  await assert.rejects(search.execute("cancelled", { endpoint_id: "test.endpoint" }, controller.signal));
  assert.equal(fetched, false);

  const active = new AbortController();
  const waitingSearch = createJustOneAPISearchTool({
    token: "test-token",
    fetchImpl: (async (_input, init) => {
      active.abort();
      init?.signal?.throwIfAborted();
      throw new Error("expected cancellation");
    }) as typeof fetch,
  });
  await assert.rejects(waitingSearch.execute("active", { endpoint_id: "test.endpoint" }, active.signal));
  assert.equal(getEventListeners(active.signal, "abort").length, 0);
});

test("coding tools bind pi implementations to the current Collection", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "fx-tools-"));
  try {
    const tools = builtinTools(cwd);
    assert.deepEqual(
      tools.map((tool) => tool.name),
      ["read", "edit", "bash", "write", "search"],
    );

    const write = tools.find((tool) => tool.name === "write");
    const read = tools.find((tool) => tool.name === "read");
    const edit = tools.find((tool) => tool.name === "edit");
    const bash = tools.find((tool) => tool.name === "bash");
    assert.ok(write && read && edit && bash);

    const bashSchema = bash.parameters as { required?: string[]; properties?: Record<string, unknown> };
    assert.deepEqual(bashSchema.required, ["intent", "command"]);
    assert.deepEqual(Object.keys(bashSchema.properties ?? {}), ["intent", "command", "timeout"]);

    await write.execute("write-1", { path: "note.txt", content: "hello\n" }, undefined);
    const readResult = await read.execute("read-1", { path: "note.txt" }, undefined);
    assert.match(text(readResult), /hello/);

    const editResult = await edit.execute("edit-1", {
      path: "note.txt",
      edits: [{ oldText: "hello", newText: "fx" }],
    }, undefined);
    assert.match(text(editResult), /Successfully replaced 1 block/);
    assert.equal(await readFile(join(cwd, "note.txt"), "utf8"), "fx\n");

    const bashResult = await bash.execute("bash-1", {
      intent: "Confirm that the shell tool is ready.",
      command: "printf tool-ready",
    }, undefined);
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

test("Taobao search sends a compact whitelist to the agent and structured data to the UI", async () => {
  const upstream = {
    success: true,
    code: 0,
    data: {
      model: {
        page: { pageNo: 1, pageSize: 2, totalItems: 31, totalPages: 16 },
        itemList: [
          {
            itemId: "1001",
            itemName: "家用意式咖啡机",
            itemSubName: "", // Empty fields must disappear from the presentation.
            // This is the hostname returned by the live search API. Its TLS
            // certificate does not cover the extra `g.search` label.
            picUrlFull: "https://g.search2.alicdn.com/coffee.jpg",
            priceZKYuanDouble: 399,
            priceYuanDouble: 599,
            orderPayUV: "200+",
            shopName: "示例电器店",
            itemLoc: "浙江 宁波",
            discntType: "0",
            trackingPayload: { huge: "not useful to either consumer" },
          },
          {
            itemId: "1002",
            itemName: "便携咖啡机",
            priceZKYuanDouble: 199,
            priceYuanDouble: 199,
          },
        ],
        propertyList: [{ id: "large-filter-payload" }],
      },
    },
    raw: { duplicated: "upstream data" },
    next_step: { params: { page: 2 } },
  };
  const fetchImpl = (async (_input: string | URL | Request, init?: RequestInit) => {
    const request = JSON.parse(String(init?.body));
    return new Response([
      "event: message",
      `data: ${JSON.stringify({
        result: {
          content: [{ type: "text", text: JSON.stringify(upstream) }],
          structuredContent: upstream,
          isError: false,
        },
        jsonrpc: "2.0",
        id: request.id,
      })}`,
      "",
    ].join("\n"), { status: 200, headers: { "Content-Type": "text/event-stream" } });
  }) as typeof fetch;

  const search = createJustOneAPISearchTool({ token: "test-token", fetchImpl });
  const result = await search.execute("search-taobao", {
    endpoint_id: "taobao.search_item_list_v1",
    params: { keyword: "咖啡机", page: 1 },
  }, undefined) as any;
  const agentText = text(result);

  assert.match(agentText, /^TAOBAO_PRODUCTS q="咖啡机" page=1\/16 total=31 count=2/m);
  assert.match(agentText, /id=1001 \| ¥399 \| original=¥599 \| buyers=200\+/);
  assert.doesNotMatch(agentText, /raw|propertyList|trackingPayload|picUrlFull/);
  assert.equal(result.details.presentation.platform, "taobao");
  assert.equal(result.details.presentation.kind, "product-list");
  assert.equal(result.details.presentation.data.items[0].imageURL, "https://img.alicdn.com/coffee.jpg");
  assert.equal(result.details.presentation.data.items[0].subtitle, undefined);
  assert.equal(result.details.presentation.data.items[0].discountLabel, undefined);
  assert.equal(result.details.presentation.data.items[1].originalPrice, undefined);
  assert.equal(result.details.presentation.summary.nextPage, 2);
});

test("search turns a JustOneAPI business failure into a tool error", async () => {
  const fetchImpl = (async (_input: string | URL | Request, init?: RequestInit) => {
    const request = JSON.parse(String(init?.body));
    const upstream = { success: false, code: 301, message: "采集失败", data: null };
    return new Response([
      "event: message",
      `data: ${JSON.stringify({
        result: { content: [{ type: "text", text: JSON.stringify(upstream) }], structuredContent: upstream },
        jsonrpc: "2.0",
        id: request.id,
      })}`,
      "",
    ].join("\n"), { status: 200, headers: { "Content-Type": "text/event-stream" } });
  }) as typeof fetch;
  const search = createJustOneAPISearchTool({ token: "test-token", fetchImpl });

  await assert.rejects(
    () => search.execute("search-failed", {
      endpoint_id: "taobao.get_item_sale_v1",
      params: { item_id: "1001" },
    }, undefined),
    /Search failed: \[301\] 采集失败/,
  );
});
