#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const referencePath = process.argv[2];
const outputPath = process.argv[3] ?? "/private/tmp/justoneapi-openapi-en.json";
if (!referencePath) {
  console.error("Usage: fetch-justoneapi-openapi-en.mjs <reference-openapi.json> [output.json]");
  process.exit(2);
}

const reference = JSON.parse(await readFile(resolve(referencePath), "utf8"));
const targetPaths = new Set(Object.keys(reference.paths ?? {}));
const headers = { "user-agent": "Curatez OpenAPI context builder" };

async function fetchText(url, attempts = 3) {
  let failure;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetch(url, { headers, signal: AbortSignal.timeout(30_000) });
      if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
      return await response.text();
    } catch (error) {
      failure = error;
      if (attempt < attempts) await new Promise((resolveDelay) => setTimeout(resolveDelay, 300 * attempt));
    }
  }
  throw new Error(`Unable to fetch ${url}: ${failure}`);
}

async function mapConcurrent(values, concurrency, operation) {
  const results = new Array(values.length);
  let nextIndex = 0;
  async function worker() {
    while (nextIndex < values.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await operation(values[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, values.length) }, worker));
  return results;
}

const sitemap = await fetchText("https://docs.justoneapi.com/en/sitemap.xml");
const pageURLs = [...sitemap.matchAll(/<loc>(https:\/\/docs\.justoneapi\.com\/en\/api\/[^<]+)<\/loc>/g)]
  .map((match) => match[1])
  .filter((url) => !url.endsWith("/"));

console.log(`Scanning ${pageURLs.length} official English API pages...`);
const discovered = await mapConcurrent(pageURLs, 16, async (url) => {
  try {
    const html = await fetchText(url);
    return html.match(/https:\/\/docs\.justoneapi\.com\/openapi\/[^"< ]+-en\.json/)?.[0] ?? null;
  } catch (error) {
    console.warn(String(error));
    return null;
  }
});
const specificationURLs = [...new Set(discovered.filter(Boolean))];

console.log(`Reading ${specificationURLs.length} official English OpenAPI definitions...`);
const specifications = await mapConcurrent(specificationURLs, 16, async (url) => {
  try {
    return JSON.parse(await fetchText(url));
  } catch (error) {
    console.warn(String(error));
    return null;
  }
});

const paths = {};
const tagsByName = new Map();
for (const specification of specifications.filter(Boolean)) {
  for (const tag of specification.tags ?? []) tagsByName.set(tag.name, tag);
  for (const [path, pathItem] of Object.entries(specification.paths ?? {})) {
    if (targetPaths.has(path)) paths[path] = pathItem;
  }
}

const missing = [...targetPaths].filter((path) => !paths[path]);
if (missing.length) {
  throw new Error(`Missing ${missing.length} English definitions:\n${missing.join("\n")}`);
}

const aggregate = {
  openapi: "3.1.0",
  info: { title: "OpenAPI definitions", version: "v0" },
  servers: [{ url: "https://api.justoneapi.com", description: "Global production API" }],
  tags: [...tagsByName.values()],
  paths,
};
await writeFile(resolve(outputPath), `${JSON.stringify(aggregate, null, 2)}\n`, "utf8");
console.log(`Wrote ${Object.keys(paths).length} English endpoint definitions to ${outputPath}`);
