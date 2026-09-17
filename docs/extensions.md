# Extensions

Fx loads Tools, Skills, and Subagents from TypeScript files instead of saving
declaration cards into every Collection. Drop a `.ts` file into an `extensions/`
folder and it is discovered on the next run.

## Locations

| Location | Scope |
|----------|-------|
| `<collection working directory>/extensions/*.ts` | Project |
| `<collection working directory>/extensions/*/index.ts` | Project (directory) |
| `~/.fx/extensions/*.ts` | Global (every project) |
| `~/.fx/extensions/*/index.ts` | Global (directory) |

Files load in this order: global first, then project. On a name collision the
project definition wins, and both override a built-in Tool with the same name.
Within one folder, files load in file-name order; the last registration of a
name wins.

The collection working directory is the folder shown as `CWD` in the Library
toolbar (for example `~/repos/product_search`), not the Collection folder itself.

## Writing an extension

An extension default-exports a factory that receives a small registration API.
TypeScript is loaded at runtime, so no build step is required:

```ts
// <working dir>/extensions/greet.ts
import { Type } from "typebox";

export default function (fx) {
  fx.registerTool({
    name: "greet",
    label: "Greet",
    description: "Greet someone by name.",
    parameters: Type.Object({ name: Type.String() }),
    async execute(_toolCallId, params, signal) {
      return {
        content: [{ type: "text", text: `Hello, ${params.name}!` }],
        details: {},
      };
    },
  });

  fx.registerSkill({
    name: "research",
    description: "Structured web research.",
    instructions: "# Steps\n1. Search broadly.\n2. Cite sources.",
  });

  fx.registerSubagent({
    name: "scout",
    description: "Read-only reconnaissance.",
    system: "You are a read-only scout. Return concise findings.",
    tools: ["read", "bash"],
    skills: ["research"],
  });
}
```

`import { Type } from "typebox"` and imports of
`@earendil-works/pi-agent-core` / `@earendil-works/pi-ai` resolve to the runtime's
own copies, so a project extension does not need its own `node_modules`.

### API

```ts
interface FxExtensionApi {
  readonly cwd: string;        // runtime working directory
  readonly projectDir: string; // folder that owns extensions/

  registerTool(tool): void;
  registerSkill(skill): void;
  registerSubagent(subagent): void;
}
```

- Tool: `{ name, label?, description, parameters, execute }` — the pi-agent-core
  `AgentTool` shape.
- Skill: `{ name, description, instructions }`.
- Subagent: `{ name, description, system, tools?, skills?, model?, fork? }`.

A malformed file is reported as a diagnostic and skipped; it never aborts the
other extensions or the run.

## Using extensions in a Session

Tools, Skills, and Subagents stay opt-in. In the Context editor, add a Tool,
Skill, or Subagent item and pick it from the project catalog. The catalog lists
the built-in runtime tools plus everything discovered under `extensions/`.

Only the selected items become available to that Agent:

- a selected Tool is registered for the run;
- a selected Skill appears in `<available_skills>` and is loaded with
  `load_skill`;
- a selected Subagent appears in `<available_subagents>` and is invoked with
  `subagent`.

Skill `instructions` and Subagent `system` come from the extension registry. If
the notebook item carries its own body, that body wins — this keeps older
Sessions self-contained.

## Inspecting the catalog

The same catalog the picker uses can be printed from the command line:

```bash
node Runtime/dist/cli.js catalog --project-dir "<working dir>"
```

It prints the merged Tool list (with a `builtin` flag), Skills, Subagents, and
any load diagnostics as JSON.

## Security

Extensions are trusted code. They run inside the Fx runtime process with the
same filesystem and network access as Fx itself. Only add extensions from
sources you trust. There is no sandbox.
