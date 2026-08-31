#!/usr/bin/env node
import { randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const projectRoot = resolve(import.meta.dirname, "..");
const envPath = resolve(projectRoot, "LocalGateway/.env");
const gatewayBaseURL = "http://127.0.0.1:8080";
const keychainService = "com.curatez.model.sub2api";
const keychainAccount = "curatez";
const compliancePhrase = "我已阅读、理解并同意 Sub2API 部署与运营合规承诺";

function secret(bytes = 32) {
  return randomBytes(bytes).toString("hex");
}

async function initializeEnvironment() {
  try {
    await readFile(envPath);
    console.log("Local gateway environment already exists.");
    return;
  } catch {}
  const lines = [
    "ADMIN_EMAIL=curatez@sub2api.local",
    `ADMIN_PASSWORD=${secret()}`,
    `POSTGRES_PASSWORD=${secret()}`,
    `JWT_SECRET=${secret()}`,
    `TOTP_ENCRYPTION_KEY=${secret()}`,
    "",
  ];
  await mkdir(dirname(envPath), { recursive: true });
  await writeFile(envPath, lines.join("\n"), { mode: 0o600, flag: "wx" });
  await chmod(envPath, 0o600);
  console.log("Created a mode-600 local gateway environment.");
}

async function readEnv() {
  const values = {};
  for (const line of (await readFile(envPath, "utf8")).split(/\r?\n/)) {
    const match = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (match) values[match[1]] = match[2];
  }
  return values;
}

async function request(path, { token, apiKey, method = "GET", body } = {}) {
  const response = await fetch(`${gatewayBaseURL}${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await response.text();
  let value;
  try { value = text ? JSON.parse(text) : {}; } catch { value = {}; }
  if (!response.ok || (typeof value.code === "number" && value.code !== 0)) {
    throw new Error(`${method} ${path} failed (${response.status}): ${value.message ?? "unexpected response"}`);
  }
  return value.data ?? value;
}

async function waitForGateway() {
  for (let attempt = 0; attempt < 90; attempt += 1) {
    try {
      const response = await fetch(`${gatewayBaseURL}/health`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolveWait) => setTimeout(resolveWait, 2_000));
  }
  throw new Error("Sub2API did not become healthy within 180 seconds.");
}

async function loginAsAdministrator() {
  await waitForGateway();
  const env = await readEnv();
  const login = await request("/api/v1/auth/login", {
    method: "POST",
    body: { email: env.ADMIN_EMAIL, password: env.ADMIN_PASSWORD },
  });
  const token = login?.access_token;
  if (typeof token !== "string" || !token) {
    throw new Error("Sub2API login did not return an access token.");
  }
  return token;
}

async function acceptCompliance() {
  const token = await loginAsAdministrator();
  await request("/api/v1/admin/compliance/accept", {
    token,
    method: "POST",
    body: { phrase: compliancePhrase, language: "zh" },
  });
  console.log("Recorded the administrator compliance acknowledgement.");
}

function listItems(data) {
  if (Array.isArray(data)) return data;
  if (Array.isArray(data?.items)) return data.items;
  return [];
}

async function ensureOpenAIGroup(token) {
  const listed = await request("/api/v1/admin/groups?page=1&page_size=100", { token });
  let group = listItems(listed).find((item) => item.platform === "openai" && item.name === "curatez-openai");
  if (!group) {
    group = await request("/api/v1/admin/groups", {
      token,
      method: "POST",
      body: {
        name: "curatez-openai",
        description: "Local Curatez Codex gateway",
        platform: "openai",
        rate_multiplier: 1,
        subscription_type: "standard",
        max_reasoning_effort: "max",
      },
    });
  }
  if (!Number.isInteger(group?.id)) throw new Error("Unable to resolve the Curatez OpenAI group.");
  return group.id;
}

async function ensureHostProxy(token) {
  const listed = await request("/api/v1/admin/proxies?page=1&page_size=100", { token });
  let proxy = listItems(listed).find((item) => item.name === "Curatez Host Proxy");
  if (!proxy) {
    proxy = await request("/api/v1/admin/proxies", {
      token,
      method: "POST",
      body: {
        name: "Curatez Host Proxy",
        protocol: "http",
        host: "host.docker.internal",
        port: 15236,
        fallback_mode: "none",
      },
    });
  }
  if (!Number.isInteger(proxy?.id)) throw new Error("Unable to resolve the host proxy.");
  return proxy.id;
}

async function ensureLocalGatewayBalance(token) {
  const env = await readEnv();
  const listed = await request("/api/v1/admin/users?page=1&page_size=100", { token });
  const administrator = listItems(listed).find((item) => item.email === env.ADMIN_EMAIL);
  if (!Number.isInteger(administrator?.id)) {
    throw new Error("Unable to resolve the local Sub2API administrator.");
  }
  if (Number(administrator.balance ?? 0) < 1_000) {
    await request(`/api/v1/admin/users/${administrator.id}/balance`, {
      token,
      method: "POST",
      body: {
        balance: 10_000,
        operation: "set",
        notes: "Local-only Curatez gateway accounting allowance",
      },
    });
  }
}

async function ensureAPIKey(token, groupID) {
  const listed = await request("/api/v1/keys?page=1&page_size=100", { token });
  let key = listItems(listed).find((item) => item.name === "Curatez Local Runtime" && item.group_id === groupID)?.key;
  if (!key) {
    const created = await request("/api/v1/keys", {
      token,
      method: "POST",
      body: { name: "Curatez Local Runtime", group_id: groupID },
    });
    key = created?.key;
  }
  if (typeof key !== "string" || !key) throw new Error("Sub2API did not return an API key.");
  return key;
}

async function storeKeychainAPIKey(apiKey) {
  await execFileAsync("/usr/bin/security", [
    "add-generic-password", "-U",
    "-s", keychainService,
    "-a", keychainAccount,
    "-w", apiKey,
  ]);
}

async function updateFxSettings() {
  const settingsPath = resolve(homedir(), ".fx/settings.json");
  let settings = {};
  try { settings = JSON.parse(await readFile(settingsPath, "utf8")); } catch {}
  const managedModels = [
    {
      spec: "sub2api/gpt-5.6-sol",
      name: "GPT-5.6 Sol",
      reasoningEfforts: ["minimal", "low", "medium", "high", "xhigh", "max"],
    },
    { spec: "deepseek/deepseek-v4-flash", name: "DeepSeek V4 Flash" },
    { spec: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro" },
  ];
  const managedSpecs = new Set(managedModels.map((model) => model.spec));
  const models = Array.isArray(settings.models)
    ? settings.models.filter((item) => !managedSpecs.has(typeof item === "string" ? item : item?.spec))
    : [];
  settings.defaultModel = managedModels[0].spec;
  settings.models = [...managedModels, ...models];
  settings.providers = {
    ...(settings.providers ?? {}),
    sub2api: {
      api: "openai-responses",
      baseUrl: `${gatewayBaseURL}/v1`,
      keychainService,
      keychainAccount,
      models: [{
        id: "gpt-5.6-sol",
        name: "GPT-5.6 Sol",
        reasoning: true,
        input: ["text", "image"],
        contextWindow: 1_000_000,
        maxTokens: 128_000,
      }],
    },
  };
  await mkdir(dirname(settingsPath), { recursive: true });
  await writeFile(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, { mode: 0o600 });
  await chmod(settingsPath, 0o600);
}

async function configureGateway() {
  const token = await loginAsAdministrator();

  const groupID = await ensureOpenAIGroup(token);
  const proxyID = await ensureHostProxy(token);
  await ensureLocalGatewayBalance(token);
  const codexSession = await readFile(resolve(homedir(), ".codex/auth.json"), "utf8");
  const imported = await request("/api/v1/admin/accounts/import/codex-session", {
    token,
    method: "POST",
    body: {
      content: codexSession,
      name: "Curatez Codex Subscription",
      group_ids: [groupID],
      proxy_id: proxyID,
      update_existing: true,
      skip_default_group_bind: true,
    },
  });
  if ((imported?.failed ?? 0) > 0) throw new Error("Codex session import failed.");

  const apiKey = await ensureAPIKey(token, groupID);
  await storeKeychainAPIKey(apiKey);
  await updateFxSettings();

  const models = await request("/v1/models?client_version=0.144.0", { apiKey });
  const modelIDs = (models?.data ?? models?.models ?? []).map((item) => item.id ?? item.slug).filter(Boolean);
  if (!modelIDs.includes("gpt-5.6-sol")) {
    throw new Error("The connected Codex account did not advertise gpt-5.6-sol.");
  }
  console.log("Configured GPT-5.6 Sol through the local-only Sub2API gateway.");
}

const command = process.argv[2] ?? "configure";
if (command === "init-env") await initializeEnvironment();
else if (command === "accept-compliance") await acceptCompliance();
else if (command === "update-settings") await updateFxSettings();
else if (command === "configure") await configureGateway();
else throw new Error(`Unknown command: ${command}`);
