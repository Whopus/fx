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
