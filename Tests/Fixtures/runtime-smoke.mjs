// Offline fixture for the real Swift Process/pipe/cancellation boundary.
import { readFile, writeFile } from "node:fs/promises";
const path = process.argv[3];
const notebook = JSON.parse(await readFile(path, "utf8"));
const query = notebook.cells[0].cells.find((cell) => cell.type === "query").content[0].text;
if (query === "fail") throw new Error("intentional offline fixture failure");
const event = (type, data = {}) => process.stdout.write(JSON.stringify({ type, time: new Date().toISOString(), data }) + "\n");
if (query === "cancel") {
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 20_000);
    process.once("SIGTERM", () => { clearTimeout(timer); resolve(); });
    event("fx/round_start");
  });
} else {
  event("message_update", { assistantMessageEvent: { type: "text_start", contentIndex: 0 } });
  for (let i = 0; i < 128; i++) event("message_update", {
    assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "字" },
  });
  event("message_update", { assistantMessageEvent: { type: "text_end", contentIndex: 0, content: "字".repeat(128) } });
}
notebook.cells.push({
  type: "output", runId: "offline", status: "completed", final: "字".repeat(128),
  startedAt: new Date().toISOString(), endedAt: new Date().toISOString(),
});
await writeFile(path, JSON.stringify(notebook));
