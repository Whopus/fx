import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createProvider, type Api, type Model, type Models } from "@earendil-works/pi-ai";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";

const execFileAsync = promisify(execFile);

interface PiModelDefinition {
  id: string;
  name?: string;
  reasoning?: boolean;
  input?: Array<"text" | "image">;
  cost?: Model<Api>["cost"];
  contextWindow?: number;
  maxTokens?: number;
  compat?: Record<string, unknown>;
}
interface PiProviderDefinition {
  baseUrl?: string;
  api?: string;
  apiKey?: string;
  apiKeyEnv?: string;
  keychainService?: string;
  keychainAccount?: string;
  compat?: Record<string, unknown>;
  models?: PiModelDefinition[];
}
interface PiModelsFile { providers?: Record<string, PiProviderDefinition>; }
interface PiSettingsFile { defaultProvider?: string; defaultModel?: string; }
interface FxSettingsFile {
  defaultModel?: string;
  providers?: Record<string, PiProviderDefinition>;
}
export interface SafeModelInfo {
  spec: string;
  name: string;
  provider: string;
  input: Array<"text" | "image">;
  reasoning: boolean;
}
export interface ModelRegistry { models: Models; configured: SafeModelInfo[]; defaultModel?: string; }

async function readJson<T>(path: string): Promise<T | undefined> {
  try { return JSON.parse(await readFile(path, "utf8")) as T; } catch { return undefined; }
}

async function readEnv(path: string): Promise<Record<string, string>> {
  try {
    const result: Record<string, string> = {};
    for (const line of (await readFile(path, "utf8")).split(/\r?\n/)) {
      const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
      if (!match?.[1] || match[2] === undefined) continue;
      result[match[1]] = match[2].trim().replace(/^(['"])(.*)\1$/, "$2");
    }
    return result;
  } catch { return {}; }
}

async function keychainSecret(service: string, account: string): Promise<string | undefined> {
  try {
    const { stdout } = await execFileAsync("/usr/bin/security", [
      "find-generic-password",
      "-s", service,
      "-a", account,
      "-w",
    ]);
    return stdout.trim() || undefined;
  } catch {
    return undefined;
  }
}

async function providerCredential(definition: PiProviderDefinition): Promise<{ apiKey: string; source: string } | undefined> {
  if (definition.apiKey?.trim()) return { apiKey: definition.apiKey.trim(), source: "model settings" };
  if (definition.apiKeyEnv) {
    const apiKey = process.env[definition.apiKeyEnv]?.trim();
    if (apiKey) return { apiKey, source: definition.apiKeyEnv };
  }
  if (definition.keychainService) {
    const account = definition.keychainAccount?.trim() || "curatez";
    const apiKey = await keychainSecret(definition.keychainService, account);
    if (apiKey) return { apiKey, source: `Keychain:${definition.keychainService}/${account}` };
  }
  return undefined;
}

/**
 * Curatez owns this registry. It preserves pi's provider/model semantics and
 * credentials never cross the runtime process boundary.
 */
export async function loadModelRegistry(
  agentHome = resolve(homedir(), ".pi/agent"),
  fxSettingsPath = resolve(homedir(), ".fx/settings.json"),
): Promise<ModelRegistry> {
  const models = builtinModels();
  const file = await readJson<PiModelsFile>(resolve(agentHome, "models.json"));
  const settings = await readJson<PiSettingsFile>(resolve(agentHome, "settings.json"));
  const fxSettings = await readJson<FxSettingsFile>(fxSettingsPath);
  const configured: SafeModelInfo[] = [];

  const registerOpenAIProvider = (
    providerId: string,
    baseUrl: string,
    apiKey: string,
    source: string,
    definitions: Array<Omit<Model<"openai-completions">, "api" | "provider" | "baseUrl">>,
  ) => {
    const providerModels = definitions.map((definition): Model<"openai-completions"> => ({
      ...definition,
      api: "openai-completions",
      provider: providerId,
      baseUrl,
    }));
    models.setProvider(createProvider({
      id: providerId,
      name: providerId,
      baseUrl,
      auth: {
        apiKey: {
          name: `${providerId} API key`,
          check: async () => ({ type: "api_key", source }),
          resolve: async () => ({ auth: { apiKey }, source }),
        },
      },
      models: providerModels,
      api: openAICompletionsApi(),
    }));
    configured.push(...providerModels.map((model) => ({
      spec: `${providerId}/${model.id}`,
      name: model.name,
      provider: providerId,
      input: [...model.input],
      reasoning: model.reasoning,
    })));
  };

  const registerOpenAIResponsesProvider = (
    providerId: string,
    baseUrl: string,
    apiKey: string,
    source: string,
    definitions: PiModelDefinition[],
    providerCompat: Record<string, unknown> = {},
  ) => {
    const providerModels = definitions.map((definition): Model<"openai-responses"> => ({
      id: definition.id,
      name: definition.name ?? definition.id,
      api: "openai-responses",
      provider: providerId,
      baseUrl,
      reasoning: definition.reasoning ?? false,
      input: definition.input ?? ["text"],
      cost: definition.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: definition.contextWindow ?? 1_000_000,
      maxTokens: definition.maxTokens ?? 128_000,
      compat: { ...providerCompat, ...(definition.compat ?? {}) } as NonNullable<Model<"openai-responses">["compat"]>,
    }));
    models.setProvider(createProvider({
      id: providerId,
      name: providerId,
      baseUrl,
      auth: {
        apiKey: {
          name: `${providerId} API key`,
          check: async () => ({ type: "api_key", source }),
          resolve: async () => ({ auth: { apiKey }, source }),
        },
      },
      models: providerModels,
      api: openAIResponsesApi(),
    }));
    configured.push(...providerModels.map((model) => ({
      spec: `${providerId}/${model.id}`,
      name: model.name,
      provider: providerId,
      input: [...model.input],
      reasoning: model.reasoning,
    })));
  };

  const reposRoot = process.env.CURATEZ_REPOS_ROOT ?? process.env.FX_REPOS_ROOT ?? resolve(homedir(), "repos");
  const deepseekEnvPath = process.env.CURATEZ_DEEPSEEK_ENV ?? process.env.FX_DEEPSEEK_ENV ?? resolve(reposRoot, "soda/benchmarks/.env");
  const deepseekEnv = await readEnv(deepseekEnvPath);
  const deepseekKey = process.env.DEEPSEEK_API_KEY ?? deepseekEnv.DEEPSEEK_API_KEY;
  if (deepseekKey) registerOpenAIProvider("deepseek", "https://api.deepseek.com", deepseekKey, deepseekEnvPath, [
    {
      id: "deepseek-v4-flash",
      name: "DeepSeek V4 Flash",
      reasoning: true,
      input: ["text"],
      cost: { input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0 },
      contextWindow: 1_000_000,
      maxTokens: 384_000,
      compat: { thinkingFormat: "deepseek", requiresReasoningContentOnAssistantMessages: true },
    },
    {
      id: "deepseek-v4-pro",
      name: "DeepSeek V4 Pro",
      reasoning: true,
      input: ["text"],
      cost: { input: 0.435, output: 0.87, cacheRead: 0.003625, cacheWrite: 0 },
      contextWindow: 1_000_000,
      maxTokens: 384_000,
      compat: { thinkingFormat: "deepseek", requiresReasoningContentOnAssistantMessages: true },
    },
  ]);

  const bailianEnvPath = process.env.CURATEZ_BAILIAN_ENV ?? process.env.FX_BAILIAN_ENV ?? resolve(reposRoot, "soda/benchmarks/.env.planora");
  const bailianEnv = await readEnv(bailianEnvPath);
  const bailianKey = process.env.DASHSCOPE_API_KEY ?? process.env.QWEN_API_KEY ?? bailianEnv.DASHSCOPE_API_KEY ?? bailianEnv.QWEN_API_KEY;
  const bailianBaseUrl = process.env.BAILIAN_BASE_URL ?? bailianEnv.BAILIAN_BASE_URL ?? "https://dashscope.aliyuncs.com/compatible-mode/v1";
  if (bailianKey) registerOpenAIProvider("bailian", bailianBaseUrl, bailianKey, bailianEnvPath, [
    {
      id: "qwen3.7-flash",
      name: "Qwen 3.7 Flash (百炼)",
      reasoning: true,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 262_144,
      maxTokens: 65_536,
      compat: { supportsDeveloperRole: false, supportsReasoningEffort: false, supportsStrictMode: false, thinkingFormat: "qwen" },
    },
    {
      id: "qwen3.7-max",
      name: "Qwen 3.7 Max (百炼)",
      reasoning: true,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 262_144,
      maxTokens: 65_536,
      compat: { supportsDeveloperRole: false, supportsReasoningEffort: false, supportsStrictMode: false, thinkingFormat: "qwen" },
    },
  ]);

  const externalProviders = {
    ...(file?.providers ?? {}),
    ...(fxSettings?.providers ?? {}),
  };
  for (const [providerId, definition] of Object.entries(externalProviders)) {
    if (!definition.baseUrl || !definition.models?.length || definition.api !== "openai-responses") continue;
    const credential = await providerCredential(definition);
    if (!credential) continue;
    registerOpenAIResponsesProvider(
      providerId,
      definition.baseUrl,
      credential.apiKey,
      credential.source,
      definition.models,
      definition.compat,
    );
  }

  for (const [providerId, definition] of Object.entries(file?.providers ?? {})) {
    if (!definition.apiKey || !definition.baseUrl || definition.api !== "anthropic-messages" || !definition.models?.length) continue;
    const apiKey = definition.apiKey;
    const providerModels = definition.models.map((item): Model<"anthropic-messages"> => ({
      id: item.id,
      name: item.name ?? item.id,
      api: "anthropic-messages",
      provider: providerId,
      baseUrl: definition.baseUrl!,
      reasoning: item.reasoning ?? false,
      input: item.input ?? ["text"],
      cost: item.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: item.contextWindow ?? 200_000,
      maxTokens: item.maxTokens ?? 8_192,
      compat: { ...(definition.compat ?? {}), ...(item.compat ?? {}) },
    }));
    models.setProvider(createProvider({
      id: providerId,
      name: providerId,
      baseUrl: definition.baseUrl,
      auth: {
        apiKey: {
          name: `${providerId} API key`,
          check: async () => ({ type: "api_key", source: "~/.pi/agent/models.json" }),
          resolve: async () => ({ auth: { apiKey }, source: "~/.pi/agent/models.json" }),
        },
      },
      models: providerModels,
      api: anthropicMessagesApi(),
    }));
    configured.push(...providerModels.map((model) => ({
      spec: `${providerId}/${model.id}`,
      name: model.name,
      provider: providerId,
      input: [...model.input],
      reasoning: model.reasoning,
    })));
  }

  const piDefault = settings?.defaultProvider && settings.defaultModel
    ? `${settings.defaultProvider}/${settings.defaultModel}`
    : undefined;
  const requestedDefault = process.env.CURATEZ_MODEL
    ?? process.env.FX_MODEL
    ?? fxSettings?.defaultModel
    ?? (configured.some((model) => model.spec === "deepseek/deepseek-v4-flash") ? "deepseek/deepseek-v4-flash" : piDefault);
  const defaultModel = requestedDefault && configured.some((model) => model.spec === requestedDefault)
    ? requestedDefault
    : configured[0]?.spec;
  return { models, configured, ...(defaultModel ? { defaultModel } : {}) };
}

export function resolveModel(models: Models, spec: string): Model<Api> | undefined {
  const slash = spec.indexOf("/");
  return slash > 0 ? models.getModel(spec.slice(0, slash), spec.slice(slash + 1)) : undefined;
}
