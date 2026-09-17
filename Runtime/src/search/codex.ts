import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import { homedir } from "node:os";
import { join } from "node:path";
import tls from "node:tls";

/**
 * Codex's standalone web-search backend.
 *
 * Codex does not use the slow hosted Responses-API `web_search` tool for its
 * `web.run` commands. It calls a dedicated endpoint:
 *
 *     POST {chatgpt_base_url}/codex/alpha/search   (ChatGPT auth)
 *     POST {openai_base_url}/alpha/search          (relay / api-key auth)
 *     { "id": "<session id>", "model": "<model>", "commands": { ... } }
 *
 * Results are raw title/url/snippet/ref_id entries in a few seconds. The
 * transport uses node:https directly so an HTTP proxy can be honored through a
 * CONNECT tunnel; the global fetch dispatcher does not apply NODE_USE_ENV_PROXY.
 */

export type CodexSearchMode = "api" | "chatgpt";

export interface CodexSearchConfig {
  mode: CodexSearchMode;
  url: string;
  headers: Record<string, string>;
  model: string;
  timeoutMs: number;
  proxy?: string;
}

export interface CodexSearchResult {
  type?: string;
  title?: string;
  url?: string;
  domain?: string;
  ref_id?: string;
  snippet?: string;
}

export interface CodexSearchResponse {
  results?: CodexSearchResult[];
  output?: string;
  encrypted_output?: string;
  error?: { message?: string; code?: string } | string;
  detail?: string;
}

export interface CodexRequestOptions {
  method: string;
  headers: Record<string, string>;
  body?: string;
  proxy?: string;
  signal?: AbortSignal;
  timeoutMs: number;
}

export type CodexRequest = (
  url: string,
  options: CodexRequestOptions,
) => Promise<{ status: number; text: string }>;

export interface CodexSearchOptions {
  /** Overrides `$CODEX_HOME` / `~/.codex`. */
  codexHome?: string;
  env?: NodeJS.ProcessEnv;
  /** Injectable transport; defaults to node:https with proxy support. */
  request?: CodexRequest;
}

function readFileSafe(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
}

function readJsonSafe(path: string): Record<string, unknown> | undefined {
  const raw = readFileSafe(path);
  if (!raw) return undefined;
  try {
    return JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

/** Minimal top-level TOML string lookup (good enough for `key = "value"`). */
function tomlString(text: string | undefined, key: string): string | undefined {
  if (!text) return undefined;
  const match = text.match(new RegExp(`^\\s*${key}\\s*=\\s*"([^"]*)"`, "m"));
  return match?.[1];
}

function jwtPayload(token: string | undefined): Record<string, unknown> | undefined {
  if (!token) return undefined;
  try {
    const part = token.split(".")[1];
    if (!part) return undefined;
    const padded = part + "=".repeat((4 - (part.length % 4)) % 4);
    return JSON.parse(Buffer.from(padded, "base64url").toString("utf8")) as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

/** macOS system HTTP(S) proxy, as set by VPN clients such as Clash. */
function systemProxy(): string | undefined {
  if (process.platform !== "darwin") return undefined;
  try {
    const out = execFileSync("scutil", ["--proxy"], { encoding: "utf8", timeout: 2_000 });
    const enabled = /HTTPSEnable\s*:\s*1/.test(out);
    const host = out.match(/HTTPSProxy\s*:\s*(\S+)/)?.[1];
    const port = out.match(/HTTPSPort\s*:\s*(\d+)/)?.[1];
    if (enabled && host && port) return `http://${host}:${port}`;
  } catch {
    /* ignore */
  }
  return undefined;
}

/** https.Agent that tunnels through an HTTP proxy via CONNECT. */
function createProxyAgent(proxyUrl: string): https.Agent {
  const proxy = new URL(proxyUrl);
  const proxyPort = Number(proxy.port) || (proxy.protocol === "https:" ? 443 : 80);
  const auth = proxy.username
    ? `Basic ${Buffer.from(`${decodeURIComponent(proxy.username)}:${decodeURIComponent(proxy.password)}`).toString("base64")}`
    : undefined;

  const agent = new https.Agent({ keepAlive: false });
  // Node types leave createConnection loose, so the override is cast.
  (agent as unknown as { createConnection: unknown }).createConnection = (
    options: { host?: string; port?: number; servername?: string },
    callback: (error: Error | null, socket?: tls.TLSSocket) => void,
  ) => {
    const connect = http.request({
      host: proxy.hostname,
      port: proxyPort,
      method: "CONNECT",
      path: `${options.host}:${options.port ?? 443}`,
      headers: auth ? { "Proxy-Authorization": auth } : {},
    });
    connect.once("connect", (response, socket) => {
      if (response.statusCode !== 200) {
        socket.destroy();
        callback(new Error(`Proxy CONNECT failed with status ${response.statusCode}`));
        return;
      }
      const tlsSocket = tls.connect({ socket, servername: options.servername ?? options.host });
      tlsSocket.once("secureConnect", () => callback(null, tlsSocket));
      tlsSocket.once("error", callback);
    });
    connect.once("error", callback);
    connect.end();
  };
  return agent;
}

/** Default transport: node:https with optional CONNECT-proxy tunneling. */
export const httpsRequest: CodexRequest = (url, options) => {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const request = https.request(
      {
        hostname: target.hostname,
        port: target.port || 443,
        path: `${target.pathname}${target.search}`,
        method: options.method,
        headers: options.headers,
        agent: options.proxy ? createProxyAgent(options.proxy) : undefined,
      },
      (response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.on("end", () =>
          resolve({ status: response.statusCode ?? 0, text: Buffer.concat(chunks).toString("utf8") }),
        );
      },
    );

    request.setTimeout(options.timeoutMs, () => {
      request.destroy(new Error(`Search timed out after ${options.timeoutMs}ms`));
    });

    const onAbort = () => request.destroy(new Error("Aborted"));
    options.signal?.addEventListener("abort", onAbort, { once: true });
    request.on("close", () => options.signal?.removeEventListener("abort", onAbort));
    request.on("error", reject);

    if (options.body) request.write(options.body);
    request.end();
  });
};

/** Build the api-key/relay backend when a key is available. */
function buildApiConfig(
  model: string,
  timeoutMs: number,
  proxy: string | undefined,
  codexHome: string,
  env: NodeJS.ProcessEnv,
): CodexSearchConfig | undefined {
  const auth = readJsonSafe(join(codexHome, "auth.json")) ?? {};
  const toml = readFileSafe(join(codexHome, "config.toml"));
  const baseUrl = (
    env.CODEX_SEARCH_BASE_URL ||
    tomlString(toml, "openai_base_url") ||
    "https://api.openai.com/v1"
  ).replace(/\/+$/, "");
  const apiKey =
    env.CODEX_SEARCH_API_KEY ||
    (typeof auth.OPENAI_API_KEY === "string" ? auth.OPENAI_API_KEY : undefined) ||
    env.OPENAI_API_KEY;
  if (!apiKey) return undefined;
  const config: CodexSearchConfig = {
    mode: "api",
    url: `${baseUrl}/alpha/search`,
    headers: { Authorization: `Bearer ${apiKey}` },
    model,
    timeoutMs,
  };
  if (proxy) config.proxy = proxy;
  return config;
}

/** Build the official ChatGPT backend when a valid access token is available. */
function buildChatgptConfig(
  model: string,
  timeoutMs: number,
  proxy: string | undefined,
  codexHome: string,
  env: NodeJS.ProcessEnv,
): CodexSearchConfig | undefined {
  const auth = readJsonSafe(join(codexHome, "auth.json")) ?? {};
  const tokens = (auth.tokens ?? {}) as Record<string, unknown>;
  const accessToken = typeof tokens.access_token === "string" ? tokens.access_token : undefined;
  if (!accessToken) return undefined;

  const payload = jwtPayload(accessToken) ?? {};
  const exp = typeof payload.exp === "number" ? payload.exp : undefined;
  if (exp && exp * 1000 < Date.now() - 60_000) return undefined;

  const authClaims = (payload["https://api.openai.com/auth"] ?? {}) as Record<string, unknown>;
  const accountId =
    (typeof tokens.account_id === "string" ? tokens.account_id : undefined) ??
    (typeof authClaims.chatgpt_account_id === "string" ? authClaims.chatgpt_account_id : undefined);

  const base = (env.CODEX_SEARCH_CHATGPT_URL || "https://chatgpt.com/backend-api").replace(/\/+$/, "");
  const headers: Record<string, string> = {
    Authorization: `Bearer ${accessToken}`,
    originator: "codex_cli_rs",
    "OpenAI-Beta": "responses=experimental",
    "User-Agent": "codex_cli_rs/0.154.0",
  };
  if (accountId) headers["chatgpt-account-id"] = accountId;

  const config: CodexSearchConfig = {
    mode: "chatgpt",
    url: `${base}/codex/alpha/search`,
    headers,
    model,
    timeoutMs,
  };
  const effectiveProxy = proxy ?? systemProxy();
  if (effectiveProxy) config.proxy = effectiveProxy;
  return config;
}

/**
 * Per-process client. It caches candidate backends and pins the one that last
 * succeeded so later calls do not retry a failing backend.
 */
export class CodexSearchClient {
  private readonly codexHome: string;
  private readonly env: NodeJS.ProcessEnv;
  private readonly request: CodexRequest;
  private readonly sessionID = `fx_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  private candidates: CodexSearchConfig[] | undefined;
  private pinned: CodexSearchConfig | undefined;

  constructor(options: CodexSearchOptions = {}) {
    this.env = options.env ?? process.env;
    this.codexHome = options.codexHome ?? this.env.CODEX_HOME ?? join(homedir(), ".codex");
    this.request = options.request ?? httpsRequest;
  }

  resolveConfigs(): CodexSearchConfig[] {
    if (this.candidates) return this.candidates;

    const toml = readFileSafe(join(this.codexHome, "config.toml"));
    const model = this.env.CODEX_SEARCH_MODEL || tomlString(toml, "model") || "gpt-5.6-sol";
    const timeoutMs = Number.parseInt(this.env.CODEX_SEARCH_TIMEOUT_MS ?? "", 10) || 60_000;
    const mode = (this.env.CODEX_SEARCH_MODE || "auto").toLowerCase();
    const envProxy =
      this.env.CODEX_SEARCH_PROXY ||
      this.env.HTTPS_PROXY ||
      this.env.https_proxy ||
      this.env.ALL_PROXY ||
      this.env.all_proxy;

    const api = buildApiConfig(model, timeoutMs, envProxy, this.codexHome, this.env);
    const chatgpt = buildChatgptConfig(model, timeoutMs, envProxy, this.codexHome, this.env);

    let list: CodexSearchConfig[];
    if (mode === "api") list = api ? [api] : [];
    else if (mode === "chatgpt") list = chatgpt ? [chatgpt] : [];
    else list = [chatgpt, api].filter((config): config is CodexSearchConfig => Boolean(config));

    if (list.length === 0) {
      throw new Error(
        mode === "chatgpt"
          ? `No usable ChatGPT token in ${join(this.codexHome, "auth.json")} (missing or expired). Run \`codex login\`, or use CODEX_SEARCH_MODE=api.`
          : `No web search credentials found. Add OPENAI_API_KEY to ${join(this.codexHome, "auth.json")} or set CODEX_SEARCH_API_KEY.`,
      );
    }

    this.candidates = list;
    return list;
  }

  private async requestOnce(
    config: CodexSearchConfig,
    commands: Record<string, unknown>,
    signal: AbortSignal | undefined,
  ): Promise<CodexSearchResponse> {
    let response: { status: number; text: string };
    try {
      response = await this.request(config.url, {
        method: "POST",
        headers: { ...config.headers, "Content-Type": "application/json" },
        body: JSON.stringify({ id: this.sessionID, model: config.model, commands }),
        ...(config.proxy ? { proxy: config.proxy } : {}),
        ...(signal ? { signal } : {}),
        timeoutMs: config.timeoutMs,
      });
    } catch (error) {
      if (signal?.aborted) throw new Error("Aborted");
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`${message} [${config.mode}]`);
    }

    let parsed: CodexSearchResponse;
    try {
      parsed = JSON.parse(response.text) as CodexSearchResponse;
    } catch {
      throw new Error(
        `Search backend returned non-JSON (HTTP ${response.status}) [${config.mode}]: ${response.text.slice(0, 200)}`,
      );
    }

    if (response.status < 200 || response.status >= 300 || parsed.error || parsed.detail) {
      const detail =
        (typeof parsed.error === "object" ? parsed.error?.message : parsed.error) ||
        parsed.detail ||
        `HTTP ${response.status}`;
      throw new Error(`${detail} [${config.mode}]`);
    }

    return parsed;
  }

  /** Run one command batch, trying each configured backend in order. */
  async run(commands: Record<string, unknown>, signal?: AbortSignal): Promise<CodexSearchResponse> {
    const all = this.resolveConfigs();
    const order =
      this.pinned && all.includes(this.pinned)
        ? [this.pinned, ...all.filter((config) => config !== this.pinned)]
        : all;
    const failures: string[] = [];

    for (let index = 0; index < order.length; index++) {
      const config = order[index];
      if (!config) continue;
      try {
        const response = await this.requestOnce(config, commands, signal);
        this.pinned = config;
        return response;
      } catch (error) {
        if (signal?.aborted) throw new Error("Aborted");
        failures.push(error instanceof Error ? error.message : String(error));
        this.pinned = undefined;
        if (index >= order.length - 1) throw new Error(failures.join("  |  "));
      }
    }

    throw new Error(failures.join("  |  ") || "Web search failed");
  }
}

/** Render ranked results as the compact text handed back to the model. */
export function formatCodexResults(results: readonly CodexSearchResult[]): string {
  const lines: string[] = [];
  results.forEach((result, index) => {
    const title = result.title || result.domain || result.url || "(untitled)";
    lines.push(`[${index + 1}] ${title}`);
    if (result.url) lines.push(`    ${result.url}`);
    if (result.snippet) lines.push(`    ${result.snippet.replace(/\s+/g, " ").trim()}`);
    if (result.ref_id) lines.push(`    ref_id: ${result.ref_id}`);
  });
  return lines.join("\n");
}

/** Keep tool output inside the pi default limits (2000 lines / 50KB). */
export function truncateCodexText(text: string, maxLines = 2_000, maxBytes = 50_000): string {
  const lines = text.split("\n");
  const kept = lines.length > maxLines ? lines.slice(0, maxLines) : lines;
  let content = kept.join("\n");
  let bytes = Buffer.byteLength(content, "utf8");
  if (bytes > maxBytes) {
    content = Buffer.from(content, "utf8").subarray(0, maxBytes).toString("utf8");
    bytes = Buffer.byteLength(content, "utf8");
  }
  if (kept.length === lines.length && bytes < Buffer.byteLength(text, "utf8")) {
    return content;
  }
  if (kept.length === lines.length) return content;
  return `${content}\n\n[Output truncated: showing ${kept.length} of ${lines.length} lines (${bytes} of ${Buffer.byteLength(text, "utf8")} bytes).]`;
}
