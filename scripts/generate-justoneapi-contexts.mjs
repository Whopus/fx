#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const input = process.argv[2];
const output = process.argv[3] ?? "Resources/justoneapi-contexts.json";
if (!input) {
  console.error("Usage: generate-justoneapi-contexts.mjs <openapi-zh.json> [output.json]");
  process.exit(2);
}

const document = JSON.parse(await readFile(resolve(input), "utf8"));
const tagMetadata = new Map((document.tags ?? []).map((tag) => [tag.name, tag]));
const platforms = new Map();

function snake(value) {
  return value
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[\s\-./]+/g, "_")
    .replace(/[^A-Za-z0-9_]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toLowerCase();
}

function endpointIdentity(path, operation) {
  const parts = path.split("/").filter(Boolean);
  const pathVersion = /^v\d+$/i.test(parts.at(-1) ?? "") ? parts.at(-1).toLowerCase() : null;
  const version = pathVersion ?? String(operation["x-api-version"] ?? "v1").toLowerCase();
  const actionEnd = pathVersion ? parts.length - 1 : parts.length;
  const platform = snake(parts[1]);
  const action = parts.slice(2, actionEnd).map(snake).filter(Boolean).join("_") || platform;
  return { platform, version, endpointID: `${platform}.${action}_${version}`.replace(/_+/g, "_") };
}

function parameterRows(operation) {
  const rows = [];
  for (const parameter of operation.parameters ?? []) {
    if (parameter.name === "token") continue;
    rows.push({
      name: snake(parameter.name),
      apiName: parameter.name,
      location: parameter.in,
      required: Boolean(parameter.required),
      schema: parameter.schema ?? {},
      description: parameter.description ?? parameter.schema?.description ?? "",
    });
  }
  const content = operation.requestBody?.content ?? {};
  const body = content["application/x-www-form-urlencoded"] ?? content["application/json"] ?? Object.values(content)[0];
  const bodySchema = body?.schema;
  for (const [name, schema] of Object.entries(bodySchema?.properties ?? {})) {
    if (name === "token") continue;
    rows.push({
      name: snake(name),
      apiName: name,
      location: "body",
      required: (bodySchema.required ?? []).includes(name),
      schema,
      description: schema.description ?? "",
    });
  }
  return rows;
}

for (const [path, pathItem] of Object.entries(document.paths ?? {})) {
  for (const [method, operation] of Object.entries(pathItem)) {
    if (!new Set(["get", "post", "put", "patch", "delete"]).has(method.toLowerCase())) continue;
    if (operation["x-docs-hidden"] === true) continue;
    const identity = endpointIdentity(path, operation);
    const tagName = operation.tags?.[0] ?? identity.platform;
    const tag = tagMetadata.get(tagName) ?? {};
    const platform = platforms.get(identity.platform) ?? {
      id: identity.platform,
      name: tagName,
      description: tag.description ?? "",
      aliases: tag["x-platform-aliases"] ?? [],
      endpoints: [],
    };
    platform.endpoints.push({
      ...identity,
      method: method.toUpperCase(),
      path,
      title: operation.summary ?? identity.endpointID,
      description: operation.description ?? "",
      deprecated: Boolean(operation.deprecated),
      parameters: parameterRows(operation),
      highlights: operation["x-highlights"] ?? [],
      order: Number(operation["x-order"] ?? Number.MAX_SAFE_INTEGER),
    });
    platforms.set(identity.platform, platform);
  }
}

function brief(value, maximum = 110) {
  const clean = String(value ?? "")
    .replace(/\[([^\]]+)]\([^)]*\)/g, "$1")
    .replace(/just\s*one\s*api/gi, "")
    .replace(/justoneapi/gi, "")
    .replace(/\s+/g, " ")
    .trim();
  if (clean.length <= maximum) return clean;
  const sentence = clean.slice(0, maximum).replace(/[，,；;：:]?[^。！？.!?]*$/, "").trim();
  return sentence || clean.slice(0, maximum).replace(/\s+\S*$/, "").trim();
}

function typeName(type) {
  const aliases = {
    string: "str",
    integer: "int",
    boolean: "bool",
    number: "num",
    array: "arr",
    object: "obj",
  };
  return aliases[type] ?? type ?? "str";
}

function compactSchema(row) {
  const schema = row.schema ?? {};
  const rawTypes = Array.isArray(schema.type) ? schema.type : [schema.type ?? "string"];
  let value = rawTypes.map(typeName).join("/");
  if (schema.default !== undefined) value += `=${JSON.stringify(schema.default)}`;
  if (Array.isArray(schema.enum) && schema.enum.length <= 8) {
    value += `{${schema.enum.map((item) => JSON.stringify(item)).join("|")}}`;
  }
  if (schema.minimum !== undefined) value += `>=${schema.minimum}`;
  if (schema.maximum !== undefined) value += `<=${schema.maximum}`;
  return value;
}

function parameterBrief(row) {
  const raw = String(row.description ?? "").split(/可(?:选|用)值[：:]|Available values?:/i)[0];
  const urlPrefix = raw.match(/https?:\/\/[^\s，,。)]+/i)?.[0];
  if (urlPrefix && /(?:以|开头|prefix|start|begin)/i.test(raw)) return `Prefix: ${urlPrefix}`;
  const value = brief(raw, 96);
  if (!value) return "";
  const carriesConstraint = /(?:上一|前一次|响应|返回|第一页|后续|大于|小于|至少|至多|固定|格式|必须|需要|只能|省略|留空|不支持|仅支持|只支持|从\s*\d|最大\s*\d|最小\s*\d|previous|response|first page|subsequent|greater|less than|at least|at most|fixed|format|required|must|only|omit|leave blank|unsupported|starting|maximum|minimum|https?:\/\/|yyyy)/i.test(value);
  if (carriesConstraint) return value;
  const parts = row.name.split("_");
  const obviousParts = new Set([
    "id", "keyword", "word", "search", "page", "num", "sort", "order", "by", "type",
    "cursor", "offset", "limit", "min", "max", "count", "url", "time", "date", "filter",
    "category", "content", "note", "publish", "duration", "follower", "interaction", "like",
    "comment", "share", "start", "end", "price", "user", "item", "video", "shop", "name",
    "sec", "uid",
  ]);
  if (parts.every((part) => obviousParts.has(part))) return "";
  if (/^(?:uid|bvid|aid|cid|wmid)$/i.test(row.name) && !/(?:或|也称|来自|\bor\b|also known|from)/i.test(value)) return "";
  if (/(?:唯一|unique).*(?:标识符|identifier|ID)[。.]?$/i.test(value) && !/(?:或|也称|来自|\bor\b|also known|from)/i.test(value)) return "";
  return value;
}

function usefulHighlights(endpoint) {
  return endpoint.highlights
    .filter((highlight) => {
      if (typeof highlight === "string") return true;
      return highlight?.type !== "info";
    })
    .map((highlight) => brief(typeof highlight === "string" ? highlight : highlight?.content, 128))
    .filter(Boolean)
    .slice(0, 2);
}

function render(platform) {
  platform.endpoints.sort((a, b) => a.order - b.order || a.endpointID.localeCompare(b.endpointID));
  const lines = [];

  for (const endpoint of platform.endpoints) {
    const highlights = usefulHighlights(endpoint);
    const notes = highlights.map((value) => `!${value}`).join("; ");
    lines.push(`${endpoint.endpointID} — ${endpoint.title}${endpoint.deprecated ? " [deprecated]" : ""}${notes ? `; ${notes}` : ""}`);
    for (const row of [...endpoint.parameters].sort((a, b) => Number(b.required) - Number(a.required))) {
      const purpose = parameterBrief(row);
      lines.push(`  ${row.name}${row.required ? "!" : ""}:${compactSchema(row)}${purpose ? ` ${purpose}` : ""}`);
    }
  }
  return lines.join("\n").trim() + "\n";
}

const contexts = [...platforms.values()]
  .sort((a, b) => a.name.localeCompare(b.name, "zh-CN"))
  .map((platform) => ({
    platformID: platform.id,
    title: platform.name,
    description: brief(String(platform.description ?? "").split(/，?用于|\s+for\s+/i)[0], 64),
    content: render(platform),
  }));

await writeFile(resolve(output), `${JSON.stringify(contexts, null, 2)}\n`, "utf8");
console.log(`Generated ${contexts.length} JustOneAPI platform contexts at ${output}`);
