import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  buildCatalog,
  discoverExtensionFiles,
  loadExtensionRegistry,
  mergeTools,
} from "../src/extensions.ts";

test("discovery lists top-level TypeScript entries and index.ts directories in order", async () => {
  const root = await mkdtemp(join(tmpdir(), "fx-ext-discover-"));
  try {
    const globalDir = join(root, "global");
    const projectDir = join(root, "project");
    await mkdir(join(globalDir, "group"), { recursive: true });
    await mkdir(projectDir, { recursive: true });
    await writeFile(join(globalDir, "a.ts"), "");
    await writeFile(join(globalDir, "types.d.ts"), "");
    await writeFile(join(globalDir, "readme.md"), "");
    await writeFile(join(globalDir, "group", "index.ts"), "");
    await writeFile(join(globalDir, "group", "helper.ts"), "");
    await writeFile(join(projectDir, "b.ts"), "");

    const files = await discoverExtensionFiles([globalDir, projectDir]);
    assert.deepEqual(
      files.map((file) => file.replace(root, "")),
      ["/global/a.ts", "/global/group/index.ts", "/project/b.ts"],
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("project extensions override global ones for tools and definitions", async () => {
  const root = await mkdtemp(join(tmpdir(), "fx-ext-override-"));
  try {
    const home = join(root, "home");
    const project = join(root, "project");
    await mkdir(join(home, ".fx", "extensions"), { recursive: true });
    await mkdir(join(project, "extensions"), { recursive: true });
    await writeFile(join(home, ".fx", "extensions", "greet.ts"), `
export default function (fx) {
  fx.registerTool({
    name: "greet",
    label: "Greet",
    description: "global",
    parameters: { type: "object" },
    async execute() { return { content: [{ type: "text", text: "global" }], details: {} }; },
  });
  fx.registerSkill({ name: "research", description: "global research", instructions: "global steps" });
}
`);
    await writeFile(join(project, "extensions", "greet.ts"), `
export default function (fx) {
  fx.registerTool({
    name: "greet",
    label: "Greet",
    description: "project",
    parameters: { type: "object" },
    async execute() { return { content: [{ type: "text", text: "project" }], details: {} }; },
  });
  fx.registerSubagent({ name: "scout", description: "scout", system: "system" });
}
`);

    const registry = await loadExtensionRegistry({ projectDir: project, homeDir: home });
    assert.deepEqual(registry.diagnostics, []);
    assert.equal(registry.tools.length, 1);
    assert.equal(registry.tools[0]?.description, "project");
    assert.equal(registry.skills.length, 1);
    assert.equal(registry.subagents.length, 1);

    const result = await registry.tools[0]?.execute("call", {}, undefined);
    assert.equal(result?.content[0]?.text, "project");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a malformed extension is reported without aborting sibling files", async () => {
  const root = await mkdtemp(join(tmpdir(), "fx-ext-broken-"));
  try {
    const home = join(root, "home");
    const project = join(root, "project", "extensions");
    await mkdir(project, { recursive: true });
    await writeFile(join(project, "good.ts"), "export default function () {}\n");
    await writeFile(join(project, "bad.ts"), "export default 42;\n");
    await writeFile(join(project, "throws.ts"), "export default function () { throw new Error('boom'); }\n");

    const registry = await loadExtensionRegistry({ projectDir: join(root, "project"), homeDir: home });
    assert.equal(registry.diagnostics.length, 2);
    assert.deepEqual(
      registry.diagnostics.map((diagnostic) => diagnostic.file.split("/").pop()).sort(),
      ["bad.ts", "throws.ts"],
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("mergeTools keeps builtins and lets extensions override by name", () => {
  const builtin = {
    name: "read",
    label: "Read",
    description: "builtin read",
    parameters: { type: "object" },
    execute: async () => ({ content: [], details: {} }),
  };
  const extension = {
    name: "read",
    label: "Read",
    description: "extension read",
    parameters: { type: "object" },
    execute: async () => ({ content: [], details: {} }),
  };
  const added = {
    name: "greet",
    label: "Greet",
    description: "greet",
    parameters: { type: "object" },
    execute: async () => ({ content: [], details: {} }),
  };

  const merged = mergeTools([builtin], [extension, added]);
  assert.deepEqual(merged.map((tool) => tool.name).sort(), ["greet", "read"]);
  assert.equal(merged.find((tool) => tool.name === "read")?.description, "extension read");

  const catalog = buildCatalog("/tmp/project", [builtin], {
    tools: [extension, added],
    skills: [],
    subagents: [],
    diagnostics: [],
  });
  assert.deepEqual(
    catalog.tools.map((tool) => [tool.name, tool.builtin]).sort(),
    [["greet", false], ["read", false]],
  );
});
