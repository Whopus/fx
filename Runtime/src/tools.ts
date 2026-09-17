import type {
  AgentHarnessTool,
  AgentTool,
  AgentToolResult,
  AgentToolUpdateCallback,
  ExecutionEnv,
} from "@earendil-works/pi-agent-core";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import {
  createBashTool,
  createEditTool,
  createReadTool,
  createWriteTool,
  NodeExecutionEnv,
} from "@earendil-works/pi-agent-core/node";
import { Type } from "typebox";
import {
  CodexSearchClient,
  formatCodexResults,
  truncateCodexText,
  type CodexSearchOptions,
  type CodexSearchResult,
} from "./search/codex.ts";
import { adaptTaobaoResult, searchBusinessError } from "./search/taobao.ts";

const JUSTONEAPI_MCP_URL = "https://mcp.justoneapi.com/mcp";

type FetchLike = typeof fetch;

export interface JustOneAPISearchOptions {
  fetchImpl?: FetchLike;
  token?: string;
  settingsURL?: string;
}

interface JustOneAPISettings {
  justoneapi?: {
    apiKey?: unknown;
    token?: unknown;
  };
  justOneAPI?: {
    apiKey?: unknown;
    token?: unknown;
  };
  justOneAPIToken?: unknown;
}

async function loadJustOneAPIToken(settingsURL?: string): Promise<string> {
  const environmentToken = process.env.JUSTONEAPI_TOKEN?.trim();
  if (environmentToken) return environmentToken;

  const path = settingsURL ?? resolve(homedir(), ".fx/settings.json");
  let settings: JustOneAPISettings | undefined;
  try {
    settings = JSON.parse(await readFile(path, "utf8")) as JustOneAPISettings;
  } catch {
    // The settings file is optional; fall through to macOS Keychain.
  }

  const candidates = [
    settings?.justoneapi?.apiKey,
    settings?.justoneapi?.token,
    settings?.justOneAPI?.apiKey,
    settings?.justOneAPI?.token,
    settings?.justOneAPIToken,
  ];
  const token = candidates.find((value): value is string => (
    typeof value === "string" && value.trim().length > 0
  ));
  if (token) return token.trim();

  if (process.platform === "darwin") {
    try {
      const keychainToken = await new Promise<string>((resolveToken, reject) => {
        execFile(
          "/usr/bin/security",
          ["find-generic-password", "-a", "fx", "-s", "com.fx.justoneapi", "-w"],
          { encoding: "utf8", timeout: 5_000 },
          (error, stdout) => error ? reject(error) : resolveToken(stdout.trim()),
        );
      });
      if (keychainToken) return keychainToken;
    } catch {
      // Report one configuration error below without exposing Keychain output.
    }
  }

  throw new Error(
    "The search API Key is not configured in secure runtime settings.",
  );
}

function parseMcpResponse(body: string): unknown {
  const payloads = body
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trim())
    .filter((line) => line && line !== "[DONE]");
  const envelope = JSON.parse(payloads.at(-1) ?? body) as {
    error?: { message?: string };
    result?: {
      isError?: boolean;
      structuredContent?: unknown;
      content?: Array<{ type?: string; text?: string }>;
    };
  };
  if (envelope.error) throw new Error(envelope.error.message ?? "The search service request failed.");

  const result = envelope.result;
  if (!result) throw new Error("The search service returned an empty response.");
  let value = result.structuredContent;
  if (value === undefined) {
    const text = result.content?.find((part) => part.type === "text")?.text;
    if (text === undefined) throw new Error("The search service returned no readable content.");
    try {
      value = JSON.parse(text);
    } catch {
      value = text;
    }
  }
  if (result.isError) {
    const message = typeof value === "string" ? value : JSON.stringify(value);
    throw new Error(`Search failed: ${message}`);
  }
  return value;
}

async function callJustOneAPIEndpoint(
  name: "call_endpoint",
  args: Record<string, unknown>,
  token: string,
  fetchImpl: FetchLike,
  signal?: AbortSignal,
): Promise<unknown> {
  signal?.throwIfAborted();
  const timeoutController = new AbortController();
  const timeout = setTimeout(() => timeoutController.abort(), 120_000);
  const abort = () => timeoutController.abort();
  signal?.addEventListener("abort", abort, { once: true });
  try {
    const response = await fetchImpl(JUSTONEAPI_MCP_URL, {
      method: "POST",
      headers: {
        Accept: "application/json, text/event-stream",
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: crypto.randomUUID(),
        method: "tools/call",
        params: { name, arguments: args },
      }),
      signal: timeoutController.signal,
    });
    const body = await response.text();
    if (!response.ok) {
      throw new Error(`Search returned HTTP ${response.status}.`);
    }
    return parseMcpResponse(body);
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", abort);
  }
}

/**
 * Execute one endpoint from the JustOneAPI catalog. Endpoint ids and parameter
 * contracts are supplied by the platform Context items installed in Library.
 */
export interface SearchToolOptions extends JustOneAPISearchOptions {
  codex?: CodexSearchOptions;
}

interface SearchArguments {
  endpoint_id?: string;
  params?: Record<string, unknown>;
  query?: string;
  queries?: string[];
  recency_days?: number;
  domains?: string[];
  open?: string[];
  find?: string;
}

async function executeJustOneAPISearch(
  endpointID: string,
  params: Record<string, unknown>,
  options: JustOneAPISearchOptions,
  signal?: AbortSignal,
): Promise<AgentToolResult<any>> {
  const token = options.token?.trim() || await loadJustOneAPIToken(options.settingsURL);
  const value = await callJustOneAPIEndpoint(
    "call_endpoint",
    { endpoint_id: endpointID, params },
    token,
    options.fetchImpl ?? fetch,
    signal,
  );

  const businessError = searchBusinessError(value);
  if (businessError) throw new Error(`Search failed: ${businessError}`);

  const adapted = adaptTaobaoResult(endpointID, params, value);
  if (adapted) {
    return {
      content: [{ type: "text", text: adapted.text }],
      details: { operation: "search", endpointID, presentation: adapted.presentation },
    };
  }
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
    details: { operation: "search", endpointID },
  };
}

async function executeWebSearch(
  params: SearchArguments,
  client: CodexSearchClient,
  signal?: AbortSignal,
  onUpdate?: AgentToolUpdateCallback,
): Promise<AgentToolResult<any>> {
  const queries = [...(params.queries ?? [])];
  if (params.query?.trim()) queries.unshift(params.query.trim());
  const commands: Record<string, unknown> = {};
  if (queries.length) {
    commands.search_query = queries.slice(0, 4).map((query) => {
      const item: Record<string, unknown> = { q: query };
      if (params.recency_days) item.recency = params.recency_days;
      if (params.domains?.length) item.domains = params.domains;
      return item;
    });
  }
  const open = params.open ?? [];
  if (params.find && open.length === 1) {
    commands.find = [{ ref_id: open[0], pattern: params.find }];
  } else if (open.length) {
    commands.open = open.map((ref_id) => ({ ref_id }));
  }
  if (Object.keys(commands).length === 0) {
    throw new Error("Provide query/queries, open with ref_ids, or endpoint_id.");
  }

  onUpdate?.({
    content: [{ type: "text", text: queries.length ? `Searching: ${queries.join(" | ")}` : "Opening pages…" }],
    details: {},
  });

  const startedAt = Date.now();
  const response = await client.run(commands, signal);
  const results = (response.results ?? []) as CodexSearchResult[];
  const sections: string[] = [];
  if (results.length) sections.push(formatCodexResults(results));
  else if (response.output) sections.push(response.output.trim());
  else sections.push("(no results)");

  return {
    content: [{ type: "text", text: truncateCodexText(sections.join("\n\n")) }],
    details: { operation: "web-search", queries, opened: open, results, elapsedMs: Date.now() - startedAt },
  };
}

/**
 * Fx's single Search capability. Without `endpoint_id` it searches the live web
 * through the Codex backend; with `endpoint_id` it calls the exact platform
 * Context endpoint as before.
 */
export function createSearchTool(options: SearchToolOptions = {}): AgentTool<any> {
  const codex = new CodexSearchClient(options.codex);
  return {
    name: "search",
    label: "Search",
    description: [
      "Search the live web (query/queries, optional recency_days and domains) and return ranked title/url/snippet/ref_id results.",
      "Use open with ref_ids from a previous result to read pages, and find to filter one opened page.",
      "With endpoint_id, call one exact platform Context endpoint instead: code=0 succeeds, data is the payload, next_step paginates.",
      "Never invent endpoint ids or keys. External calls may incur charges.",
    ].join(" "),
    parameters: Type.Object({
      query: Type.Optional(Type.String({ description: "Web search query." })),
      queries: Type.Optional(Type.Array(Type.String(), { description: "Multiple web search queries in one call (max 4)." })),
      recency_days: Type.Optional(Type.Integer({ minimum: 1, description: "Only web results from the last N days." })),
      domains: Type.Optional(Type.Array(Type.String(), { description: "Restrict web results to these domains." })),
      open: Type.Optional(Type.Array(Type.String(), { description: "ref_ids from a previous search to open and read." })),
      find: Type.Optional(Type.String({ description: "With a single open ref_id, only return lines matching this pattern." })),
      endpoint_id: Type.Optional(Type.String({ description: "Exact endpoint_id documented by the selected platform Context." })),
      params: Type.Optional(Type.Record(Type.String(), Type.Unknown(), {
        description: "Endpoint parameters keyed by the snake_case names in the platform Context.",
      })),
    }, { additionalProperties: false }),
    execute: async (_id, rawParams, signal, onUpdate) => {
      signal?.throwIfAborted();
      const params = rawParams as SearchArguments;
      const endpointID = params.endpoint_id?.trim();
      if (endpointID) {
        return executeJustOneAPISearch(endpointID, params.params ?? {}, options, signal);
      }
      return executeWebSearch(params, codex, signal, onUpdate);
    },
  };
}

/** Backwards-compatible alias for callers that only use the platform Context path. */
export const createJustOneAPISearchTool = createSearchTool;

/**
 * Host Tool registry. A Tool Cell is a capability selector; it never embeds
 * executable code in the notebook. Fx resolves every selected name here.
 */
function bindExecutionTool(
  tool: AgentHarnessTool<{ env: ExecutionEnv }, any, any>,
  env: ExecutionEnv,
): AgentTool<any> {
  const { execute, ...definition } = tool;
  return {
    ...definition,
    execute: (toolCallId, params, signal, onUpdate) => execute(
      toolCallId,
      params,
      signal,
      onUpdate,
      { env },
    ),
  };
}

function createIntentBashTool(env: ExecutionEnv): AgentTool<any> {
  const bash = bindExecutionTool(createBashTool(), env);
  return {
    ...bash,
    description: [
      bash.description,
      "Always include intent: one concise sentence describing what the command is meant to accomplish.",
    ].join(" "),
    parameters: Type.Object({
      intent: Type.String({
        minLength: 1,
        description: "One concise sentence describing what this command is meant to accomplish.",
      }),
      command: Type.String({ description: "Bash command to execute." }),
      timeout: Type.Optional(Type.Number({ description: "Timeout in seconds; omit for no timeout." })),
    }, { additionalProperties: false }),
  };
}

export function builtinTools(cwd = process.cwd()): AgentTool<any>[] {
  const env = new NodeExecutionEnv({ cwd });
  return [
    bindExecutionTool(createReadTool(), env),
    bindExecutionTool(createEditTool(), env),
    createIntentBashTool(env),
    bindExecutionTool(createWriteTool(), env),
    createSearchTool(),
  ];
}
