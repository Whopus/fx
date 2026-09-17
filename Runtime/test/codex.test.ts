import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  CodexSearchClient,
  formatCodexResults,
  truncateCodexText,
  type CodexRequest,
} from "../src/search/codex.ts";
import { createSearchTool } from "../src/tools.ts";

function text(result: { content: Array<{ type: string; text?: string }> }): string {
  return result.content.filter((part) => part.type === "text").map((part) => part.text ?? "").join("\n");
}

function jwt(payload: Record<string, unknown>): string {
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url");
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${header}.${body}.sig`;
}

async function codexHome(auth: Record<string, unknown>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "fx-codex-"));
  await writeFile(join(dir, "auth.json"), JSON.stringify(auth), "utf8");
  return dir;
}

function okResponse(payload: unknown): Awaited<ReturnType<CodexRequest>> {
  return { status: 200, text: JSON.stringify(payload) };
}

test("chatgpt mode posts to the official backend and returns parsed results", async () => {
  const home = await codexHome({
    tokens: {
      access_token: jwt({
        exp: Math.floor(Date.now() / 1000) + 3_600,
        "https://api.openai.com/auth": { chatgpt_account_id: "acc_1" },
      }),
    },
  });
  try {
    const calls: Array<{ url: string; body: Record<string, unknown>; headers: Record<string, string> }> = [];
    const client = new CodexSearchClient({
      codexHome: home,
      env: { CODEX_SEARCH_MODE: "chatgpt" },
      request: async (url, options) => {
        calls.push({
          url,
          body: JSON.parse(options.body ?? "{}") as Record<string, unknown>,
          headers: options.headers,
        });
        return okResponse({ results: [{ title: "T", url: "https://example.com", snippet: "S", ref_id: "r1" }] });
      },
    });

    const response = await client.run({ search_query: [{ q: "hello" }] });
    assert.equal(calls.length, 1);
    assert.equal(calls[0]?.url, "https://chatgpt.com/backend-api/codex/alpha/search");
    assert.equal(calls[0]?.headers["chatgpt-account-id"], "acc_1");
    assert.deepEqual(calls[0]?.body.commands, { search_query: [{ q: "hello" }] });
    assert.equal(response.results?.[0]?.ref_id, "r1");
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("auto mode falls back from the ChatGPT backend to the api-key relay", async () => {
  const home = await codexHome({
    tokens: {
      access_token: jwt({ exp: Math.floor(Date.now() / 1000) + 3_600 }),
    },
  });
  try {
    const urls: string[] = [];
    const client = new CodexSearchClient({
      codexHome: home,
      env: {
        CODEX_SEARCH_MODE: "auto",
        CODEX_SEARCH_BASE_URL: "https://relay.example/v1",
        OPENAI_API_KEY: "sk-test",
      },
      request: async (url) => {
        urls.push(url);
        if (url.includes("/codex/alpha/search")) {
          return { status: 500, text: JSON.stringify({ error: { message: "overloaded" } }) };
        }
        return okResponse({ results: [{ title: "relay" }] });
      },
    });

    const response = await client.run({ search_query: [{ q: "x" }] });
    assert.deepEqual(urls, [
      "https://chatgpt.com/backend-api/codex/alpha/search",
      "https://relay.example/v1/alpha/search",
    ]);
    assert.equal(response.results?.[0]?.title, "relay");
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("no credentials reports a configuration error", async () => {
  const home = await codexHome({});
  try {
    const client = new CodexSearchClient({ codexHome: home, env: { CODEX_SEARCH_MODE: "api" }, request: async () => okResponse({}) });
    await assert.rejects(client.run({ search_query: [{ q: "x" }] }), /No web search credentials/);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("the unified search tool routes web queries to Codex and keeps endpoint routing", async () => {
  const home = await codexHome({
    tokens: { access_token: jwt({ exp: Math.floor(Date.now() / 1000) + 3_600 }) },
  });
  try {
    const bodies: Array<Record<string, unknown>> = [];
    const search = createSearchTool({
      codex: {
        codexHome: home,
        env: { CODEX_SEARCH_MODE: "chatgpt" },
        request: async (_url, options) => {
          bodies.push(JSON.parse(options.body ?? "{}") as Record<string, unknown>);
          return okResponse({ results: [{ title: "Result", url: "https://example.com", ref_id: "r1" }] });
        },
      },
    });

    const result = await search.execute("call", { query: "fx web search" }, undefined);
    assert.match(text(result), /\[1\] Result/);
    assert.equal((result.details as { operation?: string }).operation, "web-search");
    assert.deepEqual((bodies[0]?.commands as Record<string, unknown>).search_query, [
      { q: "fx web search" },
    ]);

    // A missing endpoint_id and no web fields is a usage error, not a JustOneAPI call.
    await assert.rejects(search.execute("call", {}, undefined), /Provide query\/queries/);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("formatting and truncation keep output compact", () => {
  const formatted = formatCodexResults([
    { title: "One", url: "https://a.example", snippet: "first   result", ref_id: "r1" },
    { url: "https://b.example" },
  ]);
  assert.equal(formatted, [
    "[1] One",
    "    https://a.example",
    "    first result",
    "    ref_id: r1",
    "[2] https://b.example",
    "    https://b.example",
  ].join("\n"));

  const truncated = truncateCodexText("a\nb\nc", 2, 50_000);
  assert.match(truncated, /^a\nb/);
  assert.match(truncated, /Output truncated: showing 2 of 3 lines/);
});
