#!/usr/bin/env bun

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

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
};

const DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1";
const DEFAULT_CONTEXT = 262144;
const DEFAULT_MAX_OUTPUT_TOKENS = 32768;
const SMALL_CONTEXT_THRESHOLD = 100000;
const SMALL_CONTEXT_MAX_OUTPUT_TOKENS = 16384;

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
  --no-tool-calling         Mark generated models as not tool-call capable
  -h, --help                Show this help

Outputs:
  <root>/kilocode/kilo.jsonc
  <root>/opencode/opencode.jsonc
  <root>/pi/models.json
  <root>/vscode/chatLanguageModels.json
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
      vision: section.values.mmproj !== undefined || section.name.split(":").includes("vision"),
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

async function writeJson(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
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

  await writeJson(join(outputRoot, "kilocode", "kilo.jsonc"), buildKiloConfig(models, options.baseUrl));
  await writeJson(join(outputRoot, "opencode", "opencode.jsonc"), buildOpencodeConfig(models, options.baseUrl));
  await writeJson(join(outputRoot, "pi", "models.json"), buildPiConfig(models, options.baseUrl));
  await writeJson(join(outputRoot, "vscode", "chatLanguageModels.json"), buildVsCodeConfig(models, options.baseUrl));

  process.stdout.write(`Generated ${models.length} model entries under ${outputRoot}\n`);
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`generate-coding-tool-configs: ${message}\n`);
  process.exit(1);
});
