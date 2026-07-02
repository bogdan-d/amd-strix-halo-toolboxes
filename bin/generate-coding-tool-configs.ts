#!/usr/bin/env bun

import { mkdir, readFile, rm, rmdir, stat, writeFile } from "node:fs/promises";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

type IniSection = {
  name: string;
  values: Record<string, string>;
};

type ModelInfo = {
  id: string;
  name: string;
  contextWindow: number;
  maxOutputTokens: number;
  maxInputTokens: number;
  reasoning: boolean;
  toolCalling: boolean;
  vision: boolean;
};

type Options = {
  preset: string;
  outputRoot: string;
  baseUrl: string;
  maxOutputTokens: number;
  defaultContext: number;
  toolCalling: boolean;
  manifest: string;
};

const DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1";
const DEFAULT_CONTEXT = 262144;
const DEFAULT_MAX_OUTPUT_TOKENS = 32768;
const SMALL_CONTEXT_THRESHOLD = 100000;
const SMALL_CONTEXT_MAX_OUTPUT_TOKENS = 16384;
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const DEFAULT_MANIFEST = join(REPO_ROOT, "coding-tool-configs.manifest.json");

function usage(exitCode = 0): never {
  const stream = exitCode === 0 ? process.stdout : process.stderr;
  stream.write(`Usage:
  bin/generate-coding-tool-configs.ts [options] <models.ini>

Generate local coding-tool model configs from a llama.cpp --models-preset INI.

Options:
  --output-root <dir>       Output root. Default: ./coding-tool-configs
  --base-url <url>          OpenAI-compatible endpoint. Default: ${DEFAULT_BASE_URL}
  --max-output-tokens <n>   Default model output budget. Default: ${DEFAULT_MAX_OUTPUT_TOKENS}
  --default-context <n>     Fallback total context when the INI has no ctx-size. Default: ${DEFAULT_CONTEXT}
  --manifest <path>         Config manifest declaring targets and enabled state. Default: ${DEFAULT_MANIFEST}
  --no-tool-calling         Mark generated models as not tool-call capable
  -h, --help                Show this help

Outputs are driven by the manifest. Each enabled config writes one file under
<output-root> at the path declared in the manifest; disabled configs are skipped.
`);
  process.exit(exitCode);
}

function parsePositiveInteger(value: string, name: string): number {
  if (!/^[0-9]+$/.test(value)) {
    throw new Error(`${name} must be a positive integer: ${value}`);
  }

  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive safe integer: ${value}`);
  }

  return parsed;
}

function parseArgs(argv: string[]): Options {
  let outputRoot = "coding-tool-configs";
  let baseUrl = DEFAULT_BASE_URL;
  let maxOutputTokens = DEFAULT_MAX_OUTPUT_TOKENS;
  let defaultContext = DEFAULT_CONTEXT;
  let toolCalling = true;
  let manifest = DEFAULT_MANIFEST;
  let preset: string | undefined;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "-h":
      case "--help":
        usage(0);
      case "--output-root":
        outputRoot = requireValue(argv, ++i, arg);
        break;
      case "--base-url":
        baseUrl = requireValue(argv, ++i, arg);
        break;
      case "--max-output-tokens":
        maxOutputTokens = parsePositiveInteger(requireValue(argv, ++i, arg), arg);
        break;
      case "--default-context":
        defaultContext = parsePositiveInteger(requireValue(argv, ++i, arg), arg);
        break;
      case "--manifest":
        manifest = requireValue(argv, ++i, arg);
        break;
      case "--no-tool-calling":
        toolCalling = false;
        break;
      default:
        if (arg.startsWith("-")) {
          throw new Error(`Unknown option: ${arg}`);
        }
        if (preset !== undefined) {
          throw new Error(`Unexpected extra argument: ${arg}`);
        }
        preset = arg;
        break;
    }
  }

  if (preset === undefined) {
    usage(1);
  }

  return {
    preset,
    outputRoot,
    baseUrl,
    maxOutputTokens,
    defaultContext,
    toolCalling,
    manifest,
  };
}

function requireValue(argv: string[], index: number, option: string): string {
  const value = argv[index];
  if (value === undefined || value.startsWith("-")) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

function stripInlineComment(value: string): string {
  let quote: "'" | '"' | undefined;

  for (let i = 0; i < value.length; i += 1) {
    const char = value[i];
    if ((char === "'" || char === '"') && (i === 0 || value[i - 1] !== "\\")) {
      quote = quote === char ? undefined : quote ?? char;
      continue;
    }
    if (quote === undefined && (char === "#" || char === ";")) {
      const previous = value[i - 1];
      if (previous === undefined || /\s/.test(previous)) {
        return value.slice(0, i).trimEnd();
      }
    }
  }

  return value.trimEnd();
}

function parseIni(input: string): IniSection[] {
  const sections: IniSection[] = [];
  let current: IniSection | undefined;

  input.split(/\r?\n/).forEach((rawLine, index) => {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("#") || line.startsWith(";")) {
      return;
    }

    const sectionMatch = /^\[([^\]]+)\]$/.exec(line);
    if (sectionMatch) {
      current = { name: sectionMatch[1], values: {} };
      sections.push(current);
      return;
    }

    const equalsIndex = rawLine.indexOf("=");
    if (equalsIndex === -1) {
      throw new Error(`Cannot parse INI line ${index + 1}: ${rawLine}`);
    }
    if (current === undefined) {
      return;
    }

    const key = rawLine.slice(0, equalsIndex).trim();
    const value = stripInlineComment(rawLine.slice(equalsIndex + 1).trim());
    current.values[key] = value;
  });

  return sections;
}

function boolFromLlama(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined) {
    return fallback;
  }

  switch (value.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
      return true;
    case "0":
    case "false":
    case "no":
    case "off":
      return false;
    default:
      return fallback;
  }
}

function numberFromSection(
  key: string,
  section: IniSection,
  globalValues: Record<string, string>,
  fallback: number,
): number {
  const raw = section.values[key] ?? globalValues[key];
  if (raw === undefined || raw === "") {
    return fallback;
  }

  return parsePositiveInteger(raw, key);
}

function effectiveContextWindow(
  section: IniSection,
  globalValues: Record<string, string>,
  fallback: number,
): number {
  const totalContext = numberFromSection("ctx-size", section, globalValues, fallback);
  const parallel = numberFromSection("parallel", section, globalValues, 1);
  const contextWindow = Math.floor(totalContext / parallel);

  if (contextWindow < 1) {
    throw new Error(
      `${section.name}: ctx-size (${totalContext}) divided by parallel (${parallel}) is less than 1`,
    );
  }

  return contextWindow;
}

function effectiveMaxOutputTokens(
  section: IniSection,
  globalValues: Record<string, string>,
  configuredFallback: number,
  contextWindow: number,
): number {
  const configured = numberFromSection("max-output-tokens", section, globalValues, configuredFallback);
  const capped = contextWindow < SMALL_CONTEXT_THRESHOLD
    ? Math.min(configured, SMALL_CONTEXT_MAX_OUTPUT_TOKENS)
    : configured;

  if (capped >= contextWindow) {
    throw new Error(
      `${section.name}: max output tokens (${capped}) must be less than context (${contextWindow})`,
    );
  }

  return capped;
}

function displayNameForModel(section: IniSection): string {
  return section.values.alias?.trim() || section.name;
}

function modelInfoFromSections(sections: IniSection[], options: Options): ModelInfo[] {
  const globalValues = sections.find((section) => section.name === "*")?.values ?? {};
  const modelSections = sections.filter((section) => section.name !== "*" && section.values.model !== undefined);

  const models = modelSections.map((section) => {
    const contextWindow = effectiveContextWindow(section, globalValues, options.defaultContext);
    const maxOutputTokens = effectiveMaxOutputTokens(section, globalValues, options.maxOutputTokens, contextWindow);

    return {
      id: section.name,
      name: displayNameForModel(section),
      contextWindow,
      maxOutputTokens,
      maxInputTokens: contextWindow - maxOutputTokens,
      reasoning: boolFromLlama(section.values.reasoning ?? globalValues.reasoning, true),
      toolCalling: options.toolCalling,
      // Variant suffixes are '~'-delimited in preset section names (see
      // generate-models-preset.sh); ':' would be canonicalized by llama.cpp.
      vision: section.values.mmproj !== undefined || section.name.split("~").includes("vision"),
    };
  });

  const seenIds = new Set<string>();
  models.forEach((model) => {
    if (seenIds.has(model.id)) {
      throw new Error(`Duplicate generated coding-tool model id: ${model.id}`);
    }
    seenIds.add(model.id);
  });

  return models;
}

function textInput(vision: boolean): string[] {
  return vision ? ["text", "image"] : ["text"];
}

function buildKiloConfig(models: ModelInfo[], baseUrl: string) {
  // Schema reference: https://app.kilo.ai/config.json
  return {
    provider: {
      "llama-cpp": {
        name: "Local LLama.cpp",
        npm: "@ai-sdk/openai-compatible",
        options: {
          baseURL: baseUrl,
        },
        models: Object.fromEntries(
          models.map((model) => [
            model.id,
            {
              name: model.name,
              reasoning: model.reasoning,
              tool_call: model.toolCalling,
              modalities: {
                input: textInput(model.vision),
                output: ["text"],
              },
              limit: {
                context: model.contextWindow,
                output: model.maxOutputTokens,
              },
            },
          ]),
        ),
      },
    },
  };
}

function buildOpencodeConfig(models: ModelInfo[], baseUrl: string) {
  // Schema reference: https://opencode.ai/config.json
  return buildKiloConfig(models, baseUrl);
}

function buildPiConfig(models: ModelInfo[], baseUrl: string) {
  return {
    providers: {
      "llama-cpp": {
        baseUrl,
        api: "openai-completions",
        apiKey: "local",
        compat: {
          supportsReasoningEffort: false,
        },
        models: models.map((model) => ({
          id: model.id,
          name: model.name,
          reasoning: model.reasoning,
          thinkingLevelMap: {
            off: null,
          },
          input: textInput(model.vision),
          contextWindow: model.contextWindow,
          maxTokens: model.maxOutputTokens,
          cost: {
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
          },
        })),
      },
    },
  };
}

function buildVsCodeConfig(models: ModelInfo[], baseUrl: string) {
  return [
    {
      name: "llama-cpp",
      vendor: "customendpoint",
      apiType: "chat-completions",
      models: models.map((model) => ({
        id: model.id,
        name: model.name,
        url: baseUrl,
        toolCalling: model.toolCalling,
        vision: model.vision,
        thinking: model.reasoning,
        maxInputTokens: model.maxInputTokens,
        maxOutputTokens: model.maxOutputTokens,
      })),
    },
  ];
}

type ManifestConfig = {
  output: string;
  enabled: boolean;
  disabledReason?: string;
};

type Manifest = {
  configs: Record<string, ManifestConfig>;
};

type ConfigBuilder = (models: ModelInfo[], baseUrl: string) => unknown;

// Each key maps a manifest entry to the function that builds that tool's config.
// The manifest is the single source of truth for which targets are emitted; a
// builder with no manifest entry (or vice versa) is a hard error so config drift
// is caught at generation time.
const CONFIG_BUILDERS: Record<string, ConfigBuilder> = {
  kilocode: buildKiloConfig,
  opencode: buildOpencodeConfig,
  pi: buildPiConfig,
  vscode: buildVsCodeConfig,
};

async function loadManifest(path: string): Promise<Manifest> {
  const raw = await readFile(path, "utf8");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to parse manifest ${path}: ${message}`);
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`Manifest ${path} must be a JSON object`);
  }

  const configs = (parsed as { configs?: unknown }).configs;
  if (typeof configs !== "object" || configs === null || Array.isArray(configs)) {
    throw new Error(`Manifest ${path} must have a "configs" object`);
  }

  const result: Record<string, ManifestConfig> = {};
  for (const [key, entry] of Object.entries(configs as Record<string, unknown>)) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      throw new Error(`Manifest ${path}: config "${key}" must be an object`);
    }

    const fields = entry as Record<string, unknown>;
    const { output, enabled, disabledReason } = fields;

    if (typeof output !== "string" || output.length === 0) {
      throw new Error(`Manifest ${path}: config "${key}" needs a non-empty string "output"`);
    }
    if (output.split(/[\\/]/).includes("..")) {
      throw new Error(
        `Manifest ${path}: config "${key}" output must not escape the output root: ${output}`,
      );
    }
    if (typeof enabled !== "boolean") {
      throw new Error(`Manifest ${path}: config "${key}" needs a boolean "enabled"`);
    }
    if (disabledReason !== undefined && typeof disabledReason !== "string") {
      throw new Error(`Manifest ${path}: config "${key}" "disabledReason" must be a string`);
    }

    result[key] = {
      output,
      enabled,
      ...(disabledReason !== undefined ? { disabledReason: disabledReason } : {}),
    };
  }

  return { configs: result };
}

function validateManifest(manifest: Manifest): void {
  const builderKeys = new Set(Object.keys(CONFIG_BUILDERS));
  const manifestKeys = new Set(Object.keys(manifest.configs));

  const missingFromManifest = [...builderKeys].filter((key) => !manifestKeys.has(key));
  if (missingFromManifest.length > 0) {
    throw new Error(
      `Manifest is missing entries for builders without a target: ${missingFromManifest.join(", ")}`,
    );
  }

  const unknownInManifest = [...manifestKeys].filter((key) => !builderKeys.has(key));
  if (unknownInManifest.length > 0) {
    throw new Error(
      `Manifest declares configs without a matching builder: ${unknownInManifest.join(", ")}`,
    );
  }

  const enabledOutputs = new Set<string>();
  for (const [key, cfg] of Object.entries(manifest.configs)) {
    if (!cfg.enabled) {
      continue;
    }
    if (enabledOutputs.has(cfg.output)) {
      throw new Error(
        `Manifest has multiple enabled configs writing to the same output: ${cfg.output} (config "${key}")`,
      );
    }
    enabledOutputs.add(cfg.output);
  }
}

async function writeJson(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
}

// Remove a stale generated file left over from when a config was enabled, plus
// any directories it leaves empty (up to, but never including, the output root).
// Keeps the generated tree consistent with the manifest without touching shared
// directories that still hold other enabled outputs.
async function pruneStaleOutput(outputRoot: string, rel: string): Promise<boolean> {
  const filePath = join(outputRoot, rel);
  let existed = false;
  try {
    await stat(filePath);
    existed = true;
  } catch {
    existed = false;
  }
  if (!existed) {
    return false;
  }

  await rm(filePath, { force: true });

  const rootPrefix = `${outputRoot}${sep}`;
  let dir = dirname(filePath);
  while (dir.startsWith(rootPrefix) && dir !== outputRoot) {
    try {
      await rmdir(dir);
    } catch {
      break;
    }
    dir = dirname(dir);
  }

  return true;
}

async function main(): Promise<void> {
  const options = parseArgs(Bun.argv.slice(2));
  const presetPath = resolve(options.preset);
  const outputRoot = resolve(options.outputRoot);
  const ini = await readFile(presetPath, "utf8");
  const models = modelInfoFromSections(parseIni(ini), options);

  if (models.length === 0) {
    throw new Error(`No model sections found in ${presetPath}`);
  }

  const manifest = await loadManifest(resolve(options.manifest));
  validateManifest(manifest);

  let written = 0;
  let skipped = 0;
  for (const [key, cfg] of Object.entries(manifest.configs)) {
    if (!cfg.enabled) {
      const reason = cfg.disabledReason ? ` (${cfg.disabledReason})` : "";
      const pruned = await pruneStaleOutput(outputRoot, cfg.output);
      const action = pruned ? `Removed stale output for disabled config` : `Skipping disabled config`;
      process.stdout.write(`${action} "${key}" -> ${cfg.output}${reason}\n`);
      skipped += 1;
      continue;
    }
    await writeJson(join(outputRoot, cfg.output), CONFIG_BUILDERS[key](models, options.baseUrl));
    written += 1;
  }

  process.stdout.write(
    `Wrote ${written} config target(s) for ${models.length} model(s); skipped ${skipped} disabled target(s) under ${outputRoot}\n`,
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`generate-coding-tool-configs: ${message}\n`);
  process.exit(1);
});
