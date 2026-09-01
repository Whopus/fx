import { randomUUID } from "node:crypto";
import { Agent, type AgentEvent, type AgentMessage, type AgentTool, type StreamFn } from "@earendil-works/pi-agent-core";
import type { Api, Model } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { compactStreamEvent } from "./event-stream.ts";
import type {
  CompiledRun,
  CuratezEvent,
  CuratezRoundStep,
  CuratezRuntime,
  OutputCell,
  RunHooks,
  SubagentCell,
} from "./types.ts";

export interface PiRuntimeOptions {
  model: Model<Api>;
  streamFn: StreamFn;
  tools?: AgentTool<any>[];
  resolveModel?: (id: string) => Model<Api> | undefined;
  maxSubagentDepth?: number;
}

function assistantText(event: AgentEvent): string {
  if (event.type !== "message_end" || event.message.role !== "assistant") return "";
  return event.message.content.filter((part) => part.type === "text").map((part) => part.text).join("");
}

function systemPrompt(compiled: CompiledRun): string {
  const sections = compiled.system.map((cell) => cell.content.trim()).filter(Boolean);
  if (compiled.context.length) {
    sections.push(`<context>\n${compiled.context.map((item) => item.value).join("\n\n")}\n</context>`);
  }
  if (compiled.skills.length) {
    sections.push(`<available_skills>\n${compiled.skills.map((skill) => `${skill.name}: ${skill.description}`).join("\n")}\nUse load_skill when a skill is relevant.\n</available_skills>`);
  }
  if (compiled.subagents.length) {
    sections.push(`<available_subagents>\n${compiled.subagents.map((agent) => `${agent.name}: ${agent.description}`).join("\n")}\nUse subagent for independent delegated work.\n</available_subagents>`);
  }
  return sections.join("\n\n");
}

function queryText(content: CompiledRun["query"]): string {
  return content.filter((part) => part.type === "text").map((part) => part.text).join("\n\n");
}

function activitySteps(messages: AgentMessage[]): CuratezRoundStep[] {
  const steps: CuratezRoundStep[] = [];
  for (const message of messages) {
    if (message.role === "assistant") {
      for (const part of message.content) {
        if (part.type === "thinking" && part.thinking.trim()) steps.push({ type: "reasoning", text: part.thinking });
        if (part.type === "toolCall") steps.push({ type: "tool-call", id: part.id, name: part.name, arguments: part.arguments });
      }
    }
    if (message.role === "toolResult") {
      const text = message.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
      steps.push({
        type: "tool-result",
        id: message.toolCallId,
        name: message.toolName,
        text,
        ...(message.details !== undefined ? { details: message.details } : {}),
        ...(message.isError ? { isError: true } : {}),
      });
    }
  }
  return steps;
}

export class PiRuntime implements CuratezRuntime {
  readonly options: PiRuntimeOptions;
  readonly depth: number;

  constructor(options: PiRuntimeOptions, depth = 0) {
    this.options = options;
    this.depth = depth;
  }

  async run(compiled: CompiledRun, hooks: RunHooks = {}): Promise<Omit<OutputCell, "id" | "type" | "forAgent">> {
    return this.runWithMessages(compiled, hooks, (hooks.resume?.messages ?? []) as AgentMessage[]);
  }

  private async runWithMessages(
    compiled: CompiledRun,
    hooks: RunHooks,
    initialMessages: AgentMessage[],
  ): Promise<Omit<OutputCell, "id" | "type" | "forAgent">> {
    const startedAt = hooks.resume?.startedAt ?? new Date().toISOString();
    // Older sessions may contain pi's cumulative `message` and `partial`
    // snapshots on every token. Normalize them when resuming as well as when
    // emitting new events so retained history stays linear in response size.
    const events: CuratezEvent[] = (hooks.resume?.events ?? []).map(compactStreamEvent);
    const emit = async (type: string, data: unknown, parentToolCallId?: string) => {
      const event = compactStreamEvent({
        type,
        time: new Date().toISOString(),
        data,
        ...(parentToolCallId ? { parentToolCallId } : {}),
      });
      events.push(event);
      await hooks.onEvent?.(event);
    };

    const selected = new Set(compiled.tools.map((cell) => cell.name));
    const tools = (this.options.tools ?? []).filter((tool) => selected.has(tool.name));
    const available = new Set((this.options.tools ?? []).map((tool) => tool.name));
    const missing = [...selected].filter((name) => !available.has(name));
    if (missing.length) throw new Error(`Unregistered Tool Cell: ${missing.join(", ")}`);

    const skillMap = new Map(compiled.skills.map((skill) => [skill.name, skill]));
    if (skillMap.size) {
      tools.push({
        name: "load_skill",
        label: "Load Skill",
        description: "Load the complete instructions for one available skill.",
        parameters: Type.Object({ name: Type.String() }),
        execute: async (_id, params) => {
          const skill = skillMap.get((params as { name: string }).name);
          if (!skill) throw new Error(`Unknown skill: ${(params as { name: string }).name}`);
          return { content: [{ type: "text", text: skill.instructions }], details: { skill: skill.name } };
        },
      });
    }

    const subagentMap = new Map(compiled.subagents.map((subagent) => [subagent.name, subagent]));
    const forkSnapshots = new Map<string, AgentMessage[]>();
    if (subagentMap.size && this.depth < (this.options.maxSubagentDepth ?? 1)) {
      tools.push(this.subagentTool(subagentMap, skillMap, forkSnapshots, emit, hooks));
    }

    const model = compiled.agent.model ? this.options.resolveModel?.(compiled.agent.model) : this.options.model;
    if (!model) throw new Error(`Unknown model: ${compiled.agent.model}`);
    const agent = new Agent({
      initialState: {
        systemPrompt: systemPrompt(compiled),
        model,
        thinkingLevel: compiled.agent.reasoning ?? "low",
        tools,
        messages: initialMessages,
      },
      streamFn: this.options.streamFn,
      toolExecution: compiled.agent.toolExecution ?? "parallel",
      beforeToolCall: async ({ toolCall, context }) => {
        if (toolCall.name === "subagent") {
          forkSnapshots.set(toolCall.id, structuredClone(context.messages.slice(0, -1)));
        }
        return undefined;
      },
    });

    let final = hooks.resume?.final ?? "";
    let roundFinal = "";
    const rounds = [...(hooks.resume?.rounds ?? [])];
    const completed = rounds.length;
    agent.subscribe(async (event) => {
      await emit(event.type, event);
      const text = assistantText(event);
      if (text) {
        final = text;
        roundFinal = text;
      }
    });
    if (hooks.signal) hooks.signal.addEventListener("abort", () => agent.abort(), { once: true });

    try {
      const contextImages = compiled.context
        .flatMap((item) => item.cell.attachments ?? [])
        .filter((attachment) => attachment.mediaType.startsWith("image/"))
        .map((attachment) => ({ type: "image" as const, data: attachment.data, mimeType: attachment.mediaType }));
      let status: "completed" | "failed" | "aborted" = "completed";
      let lastAssistant: Extract<AgentMessage, { role: "assistant" }> | undefined;
      for (const [pendingIndex, query] of compiled.queries.slice(completed).entries()) {
        const roundIndex = completed + pendingIndex;
        const roundStartedAt = new Date().toISOString();
        roundFinal = "";
        await emit("fx/round_start", { round: roundIndex + 1, queryCellId: query.cell.id });
        const queryImages = query.content
          .filter((part) => part.type === "image")
          .map((part) => ({ type: "image" as const, data: part.data, mimeType: part.mediaType }));
        const messagesBeforeRound = agent.state.messages.length;
        await agent.prompt(queryText(query.content), roundIndex === 0 ? [...contextImages, ...queryImages] : queryImages);
        lastAssistant = [...agent.state.messages].reverse().find(
          (message): message is Extract<AgentMessage, { role: "assistant" }> => message.role === "assistant",
        );
        status = lastAssistant?.stopReason === "aborted"
          ? "aborted"
          : lastAssistant?.stopReason === "error"
            ? "failed"
            : "completed";
        const endedAt = new Date().toISOString();
        rounds.push({
          index: roundIndex + 1,
          queryCellId: query.cell.id,
          final: roundFinal,
          steps: activitySteps(agent.state.messages.slice(messagesBeforeRound)),
          startedAt: roundStartedAt,
          endedAt,
        });
        await emit("fx/round_end", { round: roundIndex + 1, queryCellId: query.cell.id, status });
        if (status !== "completed") break;
      }
      const usage = lastAssistant?.usage ?? hooks.resume?.usage;
      return {
        runId: hooks.resume?.runId ?? randomUUID(),
        status,
        runtime: "pi",
        model: `${model.provider}/${model.id}`,
        ...(lastAssistant?.errorMessage ? { error: lastAssistant.errorMessage } : {}),
        final,
        rounds,
        messages: structuredClone(agent.state.messages),
        events,
        ...(usage ? { usage } : {}),
        startedAt,
        endedAt: new Date().toISOString(),
      };
    } catch (error) {
      await emit("runtime/error", { message: error instanceof Error ? error.message : String(error) });
      return {
        runId: hooks.resume?.runId ?? randomUUID(),
        status: hooks.signal?.aborted ? "aborted" : "failed",
        runtime: "pi",
        model: `${model.provider}/${model.id}`,
        error: error instanceof Error ? error.message : String(error),
        final,
        rounds,
        messages: structuredClone(agent.state.messages),
        events,
        startedAt,
        endedAt: new Date().toISOString(),
      };
    }
  }

  private subagentTool(
    subagents: Map<string, SubagentCell>,
    skills: Map<string, CompiledRun["skills"][number]>,
    forkSnapshots: Map<string, AgentMessage[]>,
    emit: (type: string, data: unknown, parentToolCallId?: string) => Promise<void>,
    hooks: RunHooks,
  ): AgentTool<any> {
    return {
      name: "subagent",
      label: "Subagent",
      description: "Delegate an independent task to one registered subagent with isolated context.",
      parameters: Type.Object({ agent: Type.String(), task: Type.String() }),
      execute: async (toolCallId, params) => {
        const input = params as { agent: string; task: string };
        const definition = subagents.get(input.agent);
        if (!definition) throw new Error(`Unknown subagent: ${input.agent}`);
        const child: CompiledRun = {
          agent: {
            id: `agent-${randomUUID()}`,
            type: "agent",
            name: definition.name,
            ...(definition.model ? { model: definition.model } : {}),
            cells: [],
          },
          system: [{ id: `system-${randomUUID()}`, type: "system", content: definition.system }],
          context: [],
          queries: [{
            cell: { id: `query-${randomUUID()}`, type: "query", content: [{ type: "text", text: input.task }] },
            content: [{ type: "text", text: input.task }],
          }],
          query: [{ type: "text", text: input.task }],
          tools: (definition.tools ?? []).map((name) => ({ id: `tool-${randomUUID()}`, type: "tool", name, description: "" })),
          skills: (definition.skills ?? []).map((name) => skills.get(name)).filter((skill): skill is CompiledRun["skills"][number] => !!skill),
          subagents: [],
        };
        const inheritedMessages = definition.fork ? forkSnapshots.get(toolCallId) ?? [] : [];
        const output = await new PiRuntime(this.options, this.depth + 1).runWithMessages(
          child,
          {
            ...(hooks.signal ? { signal: hooks.signal } : {}),
            onEvent: (event) => emit(`subagent/${event.type}`, event.data, toolCallId),
          },
          inheritedMessages,
        );
        if (output.status !== "completed") throw new Error(`Subagent ${definition.name} ${output.status}`);
        return {
          content: [{ type: "text", text: output.final }],
          details: { agent: definition.name, runId: output.runId, events: output.events, messages: output.messages },
        };
      },
    };
  }
}
