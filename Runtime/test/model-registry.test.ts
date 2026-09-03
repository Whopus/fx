import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { loadModelRegistry, resolveModel } from "../src/model-registry.ts";

test("registers a configurable OpenAI Responses model", async () => {
  const root = await mkdtemp(join(tmpdir(), "curatez-model-registry-"));
  const agentHome = join(root, "agent");
  const settingsPath = join(root, "settings.json");
  await mkdir(agentHome, { recursive: true });
  await writeFile(settingsPath, JSON.stringify({
    defaultModel: "sub2api/gpt-5.6-sol",
    providers: {
      sub2api: {
        api: "openai-responses",
        baseUrl: "http://127.0.0.1:8080/v1",
        apiKey: "test-only-key",
        models: [{
          id: "gpt-5.6-sol",
          name: "GPT-5.6 Sol",
          reasoning: true,
          input: ["text", "image"],
          contextWindow: 1_000_000,
          maxTokens: 128_000,
        }],
      },
    },
  }));

  const registry = await loadModelRegistry(agentHome, settingsPath);
  const model = resolveModel(registry.models, "sub2api/gpt-5.6-sol");

  assert.equal(registry.defaultModel, "sub2api/gpt-5.6-sol");
  assert.equal(model?.api, "openai-responses");
  assert.equal(model?.reasoning, true);
  assert.deepEqual(model?.input, ["text", "image"]);
});

test("registers a configurable OpenAI Chat Completions model", async () => {
  const root = await mkdtemp(join(tmpdir(), "curatez-model-registry-"));
  const agentHome = join(root, "agent");
  const settingsPath = join(root, "settings.json");
  await mkdir(agentHome, { recursive: true });
  await writeFile(settingsPath, JSON.stringify({
    providers: {
      wuai: {
        api: "openai-completions",
        baseUrl: "https://api.wuai.ai/v1",
        apiKey: "test-only-key",
        models: [{
          id: "claude-fable-5",
          name: "Fable 5",
          reasoning: true,
          input: ["text", "image"],
          contextWindow: 200_000,
          maxTokens: 128_000,
        }],
      },
    },
  }));

  const registry = await loadModelRegistry(agentHome, settingsPath);
  const model = resolveModel(registry.models, "wuai/claude-fable-5");

  assert.equal(model?.api, "openai-completions");
  assert.equal(model?.reasoning, true);
  assert.deepEqual(model?.input, ["text", "image"]);
});

test("registers a configurable Anthropic Messages model", async () => {
  const root = await mkdtemp(join(tmpdir(), "curatez-model-registry-"));
  const agentHome = join(root, "agent");
  const settingsPath = join(root, "settings.json");
  await mkdir(agentHome, { recursive: true });
  await writeFile(settingsPath, JSON.stringify({
    providers: {
      wuai: {
        api: "anthropic-messages",
        baseUrl: "https://api.wuai.ai/v1",
        apiKey: "test-only-key",
        models: [{
          id: "claude-fable-5",
          name: "Fable 5",
          reasoning: true,
          input: ["text", "image"],
          contextWindow: 200_000,
          maxTokens: 128_000,
        }],
      },
    },
  }));

  const registry = await loadModelRegistry(agentHome, settingsPath);
  const model = resolveModel(registry.models, "wuai/claude-fable-5");

  assert.equal(model?.api, "anthropic-messages");
  assert.equal(model?.reasoning, true);
  assert.deepEqual(model?.input, ["text", "image"]);
});

test("registers a configurable Gemini model", async () => {
  const root = await mkdtemp(join(tmpdir(), "curatez-model-registry-"));
  const agentHome = join(root, "agent");
  const settingsPath = join(root, "settings.json");
  await mkdir(agentHome, { recursive: true });
  await writeFile(settingsPath, JSON.stringify({
    providers: {
      "wuai-gemini": {
        api: "google-generative-ai",
        baseUrl: "https://api.wuai.ai/v1beta",
        apiKey: "test-only-key",
        models: [{
          id: "gemini-3.7-flash",
          name: "Gemini 3.7 Flash",
          reasoning: true,
          input: ["text", "image"],
          contextWindow: 1_000_000,
          maxTokens: 65_536,
        }],
      },
    },
  }));

  const registry = await loadModelRegistry(agentHome, settingsPath);
  const model = resolveModel(registry.models, "wuai-gemini/gemini-3.7-flash");

  assert.equal(model?.api, "google-generative-ai");
  assert.equal(model?.reasoning, true);
  assert.deepEqual(model?.input, ["text", "image"]);
});
