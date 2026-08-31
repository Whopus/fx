import type { CuratezEvent } from "./types.ts";

/**
 * Keep live token traffic incremental. pi's message_update carries both the
 * delta and a full partial message; sending that partial on every token makes
 * total UI traffic grow quadratically with response length.
 */
export function compactStreamEvent(event: CuratezEvent): CuratezEvent {
  if (!event.type.endsWith("message_update") || typeof event.data !== "object" || event.data === null) return event;
  const data = event.data as Record<string, unknown>;
  const update = data.assistantMessageEvent;
  if (typeof update !== "object" || update === null) return event;
  const source = update as Record<string, unknown>;
  const assistantMessageEvent: Record<string, unknown> = { type: source.type };
  for (const key of ["delta", "content", "contentIndex", "toolCall"] as const) {
    if (source[key] !== undefined) assistantMessageEvent[key] = source[key];
  }
  return {
    ...event,
    data: {
      type: data.type,
      assistantMessageEvent,
    },
  };
}
