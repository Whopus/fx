export type InputCellType = "system" | "context" | "query" | "tool" | "skill" | "subagent";
export type CellType = InputCellType | "agent" | "output";

export interface BaseCell {
  id: string;
  type: CellType;
  templateId?: string;
}

export interface SystemCell extends BaseCell { type: "system"; content: string; }
export interface ContextAttachment {
  id: string;
  name: string;
  mediaType: string;
  data: string;
  size: number;
}
export interface ContextCell extends BaseCell {
  type: "context";
  content?: string;
  attachments?: ContextAttachment[];
  fromOutput?: string;
  select?: "final" | "trace" | "all";
}
export interface TextPart { type: "text"; text: string; }
export interface ImagePart { type: "image"; mediaType: string; data: string; name?: string; }
export type QueryPart = TextPart | ImagePart;
export interface QueryCell extends BaseCell { type: "query"; content: QueryPart[]; }
export interface ToolCell extends BaseCell {
  type: "tool";
  name: string;
  description: string;
}
export interface SkillCell extends BaseCell {
  type: "skill";
  name: string;
  description: string;
  instructions: string;
}
export interface SubagentCell extends BaseCell {
  type: "subagent";
  name: string;
  description: string;
  system: string;
  tools?: string[];
  skills?: string[];
  model?: string;
  fork?: boolean;
}
export interface AgentCell extends BaseCell {
  type: "agent";
  name?: string;
  model?: string;
  reasoning?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
  toolExecution?: "parallel" | "sequential";
  cells: AgentInputCell[];
}
export interface CuratezEvent {
  type: string;
  time: string;
  data: unknown;
  parentToolCallId?: string;
}
export interface CuratezUsage {
  input?: number;
  output?: number;
  cacheRead?: number;
  cacheWrite?: number;
  reasoning?: number;
  totalTokens?: number;
  cost?: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
    total: number;
  };
}
export type CuratezRoundStep =
  | { type: "reasoning"; text: string }
  | { type: "tool-call"; id: string; name: string; arguments: unknown }
  | { type: "tool-result"; id: string; name: string; text: string; details?: unknown; isError?: boolean };
export interface CuratezRoundOutput {
  index: number;
  queryCellId: string;
  final: string;
  steps?: CuratezRoundStep[];
  startedAt: string;
  endedAt: string;
}
export interface OutputCell extends BaseCell {
  type: "output";
  forAgent: string;
  runId: string;
  status: "completed" | "failed" | "aborted";
  runtime?: "pi" | "static-preview";
  model?: string;
  error?: string;
  final: string;
  rounds?: CuratezRoundOutput[];
  messages?: unknown[];
  events: CuratezEvent[];
  usage?: CuratezUsage;
  startedAt: string;
  endedAt: string;
}
export type AgentInputCell = SystemCell | ContextCell | QueryCell | ToolCell | SkillCell | SubagentCell;
export type NotebookCell = AgentCell | OutputCell;
export interface CuratezNotebook { version: 1; id: string; title: string; cells: NotebookCell[]; }

export interface CompiledRun {
  agent: AgentCell;
  system: SystemCell[];
  context: Array<{ cell: ContextCell; value: string }>;
  queries: Array<{ cell: QueryCell; content: QueryPart[] }>;
  query: QueryPart[];
  tools: ToolCell[];
  skills: SkillCell[];
  subagents: SubagentCell[];
}

export interface RunHooks {
  onEvent?: (event: CuratezEvent) => void | Promise<void>;
  signal?: AbortSignal;
  resume?: OutputCell;
}
export interface CuratezRuntime {
  run(compiled: CompiledRun, hooks?: RunHooks): Promise<Omit<OutputCell, "id" | "type" | "forAgent">>;
}
