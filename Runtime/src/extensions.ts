import { readdir, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { join } from "node:path";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import { createJiti } from "jiti";

/** Definition registered by an extension for the progressive Skill loader. */
export interface FxSkillDefinition {
  name: string;
  description: string;
  instructions: string;
}

/** Definition registered by an extension for the isolated Subagent runner. */
export interface FxSubagentDefinition {
  name: string;
  description: string;
  system: string;
  tools?: string[];
  skills?: string[];
  model?: string;
  fork?: boolean;
}

/**
 * The minimal surface exposed to an extension factory. Extensions are trusted
 * code: they run in the runtime process with full filesystem and network
 * access. This API intentionally does not expose UI or session internals.
 */
export interface FxExtensionApi {
  /** Absolute working directory the Agent runs in. */
  readonly cwd: string;
  /** Same value as cwd; the project that owns the local `extensions/` folder. */
  readonly projectDir: string;
  registerTool(tool: AgentTool<any>): void;
  registerSkill(skill: FxSkillDefinition): void;
  registerSubagent(subagent: FxSubagentDefinition): void;
}

/** A non-fatal problem found while loading one extension file. */
export interface ExtensionDiagnostic {
  file: string;
  message: string;
}

/** Everything one discovery pass contributed, after override resolution. */
export interface ExtensionRegistry {
  tools: AgentTool<any>[];
  skills: FxSkillDefinition[];
  subagents: FxSubagentDefinition[];
  diagnostics: ExtensionDiagnostic[];
}

/** JSON-friendly tool metadata used by the Swift catalog picker. */
export interface ExtensionToolCatalogEntry {
  name: string;
  label: string;
  description: string;
  parameters: unknown;
  builtin: boolean;
}

export interface ExtensionCatalog {
  cwd: string;
  tools: ExtensionToolCatalogEntry[];
  skills: FxSkillDefinition[];
  subagents: FxSubagentDefinition[];
  diagnostics: ExtensionDiagnostic[];
}

export interface LoadExtensionOptions {
  projectDir: string;
  /** Runtime working directory exposed as `fx.cwd`. Defaults to projectDir. */
  cwd?: string;
  homeDir?: string;
  /** Extra directories appended after the defaults; later entries override. */
  extraDirs?: readonly string[];
}

/** The global extension folder shared by every project. */
export function defaultGlobalExtensionDir(homeDir = homedir()): string {
  return join(homeDir, ".fx", "extensions");
}

/**
 * Default discovery order: global extensions first, then the project's own
 * folder, so project files override global files with the same name.
 */
export function defaultExtensionDirs(projectDir: string, homeDir = homedir()): string[] {
  return [defaultGlobalExtensionDir(homeDir), join(projectDir, "extensions")];
}

async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

/**
 * List loadable extension entry points under each directory, in deterministic
 * order. A directory contributes top-level `.ts` files (excluding `.d.ts`) and
 * every subdirectory that contains an `index.ts`. Missing directories are
 * ignored.
 */
export async function discoverExtensionFiles(dirs: readonly string[]): Promise<string[]> {
  const files: string[] = [];
  for (const dir of dirs) {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      if (entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts")) {
        files.push(join(dir, entry.name));
      } else if (entry.isDirectory()) {
        const index = join(dir, entry.name, "index.ts");
        if (await isFile(index)) files.push(index);
      }
    }
  }
  return files;
}

const require = createRequire(import.meta.url);

/**
 * Extensions may import the same packages the runtime bundles without keeping
 * their own node_modules. Unresolvable packages stay untouched so a project
 * that does install its own copy keeps using it.
 */
function jitiAliases(): Record<string, string> {
  const aliases: Record<string, string> = {};
  for (const name of ["typebox", "@earendil-works/pi-agent-core", "@earendil-works/pi-ai"]) {
    try {
      aliases[name] = require.resolve(name);
    } catch {
      // Optional alias; the extension can still provide its own dependency.
    }
  }
  return aliases;
}

/** Load one already-discovered set of extension files. */
export async function loadExtensionFiles(
  files: readonly string[],
  context: { cwd: string; projectDir: string },
): Promise<ExtensionRegistry> {
  const { cwd, projectDir } = context;
  const tools = new Map<string, AgentTool<any>>();
  const skills = new Map<string, FxSkillDefinition>();
  const subagents = new Map<string, FxSubagentDefinition>();
  const diagnostics: ExtensionDiagnostic[] = [];
  if (!files.length) return { tools: [], skills: [], subagents: [], diagnostics };

  const jiti = createJiti(import.meta.url, {
    alias: jitiAliases(),
    interopDefault: true,
    moduleCache: false,
  });

  for (const file of files) {
    try {
      const loaded = await jiti.import(file, { default: true });
      if (typeof loaded !== "function") {
        diagnostics.push({ file, message: "Extension must default-export a function (fx) => void." });
        continue;
      }
      const api: FxExtensionApi = {
        cwd,
        projectDir,
        registerTool(tool) {
          const name = tool?.name?.trim();
          if (!name) throw new Error("registerTool requires a non-empty name");
          if (typeof tool.execute !== "function") {
            throw new Error(`Tool ${name} requires an execute function`);
          }
          tools.set(name, { ...tool, name });
        },
        registerSkill(skill) {
          const name = skill?.name?.trim();
          if (!name) throw new Error("registerSkill requires a non-empty name");
          skills.set(name, { ...skill, name });
        },
        registerSubagent(subagent) {
          const name = subagent?.name?.trim();
          if (!name) throw new Error("registerSubagent requires a non-empty name");
          subagents.set(name, { ...subagent, name });
        },
      };
      await (loaded as (api: FxExtensionApi) => unknown)(api);
    } catch (error) {
      diagnostics.push({ file, message: error instanceof Error ? error.message : String(error) });
    }
  }

  return {
    tools: [...tools.values()],
    skills: [...skills.values()],
    subagents: [...subagents.values()],
    diagnostics,
  };
}

/** Discover and load everything available to one project directory. */
export async function loadExtensionRegistry(options: LoadExtensionOptions): Promise<ExtensionRegistry> {
  const defaults = defaultExtensionDirs(options.projectDir, options.homeDir);
  const dirs = options.extraDirs?.length ? [...defaults, ...options.extraDirs] : defaults;
  const cwd = options.cwd ?? options.projectDir;
  return loadExtensionFiles(await discoverExtensionFiles(dirs), { cwd, projectDir: options.projectDir });
}

/**
 * Overlay extension tools on the built-ins. Extension definitions win on a
 * name collision, matching the extension override behavior of pi.
 */
export function mergeTools(
  builtins: readonly AgentTool<any>[],
  extensions: readonly AgentTool<any>[],
): AgentTool<any>[] {
  const merged = new Map(builtins.map((tool) => [tool.name, tool]));
  for (const tool of extensions) merged.set(tool.name, tool);
  return [...merged.values()];
}

/** Build the catalog payload consumed by the Swift Tool/Skill/Subagent pickers. */
export function buildCatalog(
  cwd: string,
  builtins: readonly AgentTool<any>[],
  registry: ExtensionRegistry,
): ExtensionCatalog {
  const extensionNames = new Set(registry.tools.map((tool) => tool.name));
  const merged = mergeTools(builtins, registry.tools);
  return {
    cwd,
    tools: merged.map((tool) => ({
      name: tool.name,
      label: tool.label,
      description: tool.description,
      parameters: tool.parameters,
      builtin: !extensionNames.has(tool.name),
    })),
    skills: registry.skills,
    subagents: registry.subagents,
    diagnostics: registry.diagnostics,
  };
}
