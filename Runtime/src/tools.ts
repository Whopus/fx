import type { AgentHarnessTool, AgentTool, ExecutionEnv } from "@earendil-works/pi-agent-core";
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
          ["find-generic-password", "-a", "curatez", "-s", "com.curatez.justoneapi", "-w"],
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
export function createJustOneAPISearchTool(
  options: JustOneAPISearchOptions = {},
): AgentTool<any> {
  return {
    name: "search",
    label: "Search",
    description: [
      "Call an exact endpoint_id with params from the selected platform Context; never invent ids or keys.",
      "Context schema uses name!:type=default{enum}; ! means required and unmarked params are optional.",
      "Success is code=0, payload is data, and pagination is next_step. External calls may incur charges.",
    ].join(" "),
    parameters: Type.Object({
      endpoint_id: Type.String({ description: "Exact endpoint_id documented by the selected platform Context." }),
      params: Type.Optional(Type.Record(Type.String(), Type.Unknown(), {
        description: "Endpoint parameters keyed by the snake_case names in the platform Context.",
      })),
    }, { additionalProperties: false }),
    execute: async (_id, rawParams, signal) => {
      const params = rawParams as {
        endpoint_id: string;
        params?: Record<string, unknown>;
      };
      const endpointID = params.endpoint_id?.trim();
      if (!endpointID) throw new Error("endpoint_id is required.");

      const token = options.token?.trim() || await loadJustOneAPIToken(options.settingsURL);
      const value = await callJustOneAPIEndpoint(
        "call_endpoint",
        { endpoint_id: endpointID, params: params.params ?? {} },
        token,
        options.fetchImpl ?? fetch,
        signal,
      );
      return {
        content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
        details: { operation: "search", endpointID },
      };
    },
  };
}

/**
 * Host Tool registry. A Tool Cell is a capability selector; it never embeds
 * executable code in the notebook. Curatez resolves every selected name here.
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

export function builtinTools(cwd = process.cwd()): AgentTool<any>[] {
  const env = new NodeExecutionEnv({ cwd });
  return [
    {
      name: "echo",
      label: "Echo",
      description: "Return the supplied text unchanged.",
      parameters: Type.Object({ text: Type.String() }),
      execute: async (_id, params) => ({
        content: [{ type: "text", text: (params as { text: string }).text }],
        details: {},
      }),
    },
    bindExecutionTool(createReadTool(), env),
    bindExecutionTool(createEditTool(), env),
    bindExecutionTool(createBashTool(), env),
    bindExecutionTool(createWriteTool(), env),
    createJustOneAPISearchTool(),
  ];
}
