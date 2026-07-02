#!/usr/bin/env bun

import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

type Options = {
  baseHome: string;
  generatedRoot: string;
  manifest: string;
  dryRun: boolean;
};

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = dirname(SCRIPT_DIR);
const DEFAULT_MANIFEST = join(REPO_ROOT, "coding-tool-configs.manifest.json");

type ConfigTarget = {
  name: string;
  generatedRel: string;
  targetRels: string[];
  merge: (current: JsonValue, generated: JsonValue) => JsonValue;
};

const TARGETS: ConfigTarget[] = [
  {
    name: "vscode",
    generatedRel: "vscode/chatLanguageModels.json",
    targetRels: [".config/Code/User/chatLanguageModels.json"],
    merge: mergeVsCodeConfig,
  },
  {
    name: "vscode-insiders",
    generatedRel: "vscode/chatLanguageModels.json",
    targetRels: [".config/Code - Insiders/User/chatLanguageModels.json"],
    merge: mergeVsCodeConfig,
  },
  {
    name: "pi",
    generatedRel: "pi/models.json",
    targetRels: [".pi/agent/models.json"],
    merge: (current, generated) => recursiveMerge(current, generated, ["providers.llama-cpp"]),
  },
  {
    name: "kilo",
    generatedRel: "kilocode/kilo.jsonc",
    targetRels: [".config/kilo/kilo.jsonc"],
    merge: (current, generated) => recursiveMerge(current, generated, ["provider.llama-cpp"]),
  },
  {
    name: "opencode",
    generatedRel: "opencode/opencode.jsonc",
    targetRels: [".config/opencode/opencode.jsonc", ".config/opencode/opencode.json"],
    merge: (current, generated) => recursiveMerge(current, generated, ["provider.llama-cpp"]),
  },
];

function usage(exitCode = 0): never {
  const stream = exitCode === 0 ? process.stdout : process.stderr;
  stream.write(`Usage:
  bin/update-user-configs.ts [options]

Merge generated local llama.cpp coding-tool configs into existing user configs.
Missing user config files are skipped.

Options:
  --base-home <dir>       Treat <dir> as "~" for target config paths. Default: ${homedir()}
  --generated-root <dir>  Generated config root. Default: ./coding-tool-configs
  --manifest <path>       Config manifest declaring enabled targets. Default: ${DEFAULT_MANIFEST}
  --dry-run              Parse and merge, but do not write files
  -h, --help             Show this help

Targets whose generated output is disabled in the manifest are skipped, so a
disabled tool is never merged into its user config even if a stale generated
file remains from a previous run.
`);
  process.exit(exitCode);
}

function parseArgs(argv: string[]): Options {
  let baseHome = homedir();
  let generatedRoot = "coding-tool-configs";
  let manifest = DEFAULT_MANIFEST;
  let dryRun = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "-h":
      case "--help":
        usage(0);
      case "--base-home":
        baseHome = requireValue(argv, ++i, arg);
        break;
      case "--generated-root":
        generatedRoot = requireValue(argv, ++i, arg);
        break;
      case "--manifest":
        manifest = requireValue(argv, ++i, arg);
        break;
      case "--dry-run":
        dryRun = true;
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }

  return {
    baseHome: resolve(baseHome),
    generatedRoot: resolve(generatedRoot),
    manifest: resolve(manifest),
    dryRun,
  };
}

function requireValue(argv: string[], index: number, option: string): string {
  const value = argv[index];
  if (value === undefined || value.startsWith("-")) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function firstExisting(paths: string[]): Promise<string | undefined> {
  for (const path of paths) {
    if (await pathExists(path)) {
      return path;
    }
  }
  return undefined;
}

function parseJsonc(input: string, path: string): JsonValue {
  try {
    return Bun.JSONC.parse(input) as JsonValue;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${path}: ${message}`);
  }
}

function isPlainObject(value: JsonValue): value is { [key: string]: JsonValue } {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function clone(value: JsonValue): JsonValue {
  if (Array.isArray(value)) {
    return value.map((item) => clone(item));
  }
  if (isPlainObject(value)) {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, clone(item)]));
  }
  return value;
}

function recursiveMerge(current: JsonValue, generated: JsonValue, replacePaths: string[], path = ""): JsonValue {
  if (replacePaths.includes(path)) {
    return clone(generated);
  }
  if (Array.isArray(current) && Array.isArray(generated)) {
    return clone(generated);
  }
  if (!isPlainObject(current) || !isPlainObject(generated)) {
    return clone(generated);
  }

  const merged: { [key: string]: JsonValue } = { ...current };
  for (const [key, value] of Object.entries(generated)) {
    const childPath = path === "" ? key : `${path}.${key}`;
    merged[key] = key in current
      ? recursiveMerge(current[key], value, replacePaths, childPath)
      : clone(value);
  }
  return merged;
}

function vscodeProviderKey(value: JsonValue): string | undefined {
  if (!isPlainObject(value)) {
    return undefined;
  }

  const name = value.name;
  const vendor = value.vendor;
  const apiType = value.apiType;
  if (typeof name !== "string" || typeof vendor !== "string" || typeof apiType !== "string") {
    return undefined;
  }

  return `${name}\u0000${vendor}\u0000${apiType}`;
}

function mergeVsCodeConfig(current: JsonValue, generated: JsonValue): JsonValue {
  if (!Array.isArray(current) || !Array.isArray(generated)) {
    return clone(generated);
  }

  const generatedByKey = new Map<string, JsonValue>();
  const generatedWithoutKey: JsonValue[] = [];
  for (const provider of generated) {
    const key = vscodeProviderKey(provider);
    if (key === undefined) {
      generatedWithoutKey.push(provider);
    } else {
      generatedByKey.set(key, provider);
    }
  }

  const merged = current.map((provider) => {
    const key = vscodeProviderKey(provider);
    if (key === undefined) {
      return clone(provider);
    }

    const generatedProvider = generatedByKey.get(key);
    if (generatedProvider === undefined) {
      return clone(provider);
    }

    generatedByKey.delete(key);
    return clone(generatedProvider);
  });

  return [
    ...merged,
    ...Array.from(generatedByKey.values()).map((provider) => clone(provider)),
    ...generatedWithoutKey.map((provider) => clone(provider)),
  ];
}

function formatJson(value: JsonValue): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

async function loadEnabledOutputs(path: string): Promise<Map<string, boolean>> {
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

  const enabledByOutput = new Map<string, boolean>();
  for (const [key, entry] of Object.entries(configs as Record<string, unknown>)) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      throw new Error(`Manifest ${path}: config "${key}" must be an object`);
    }
    const fields = entry as Record<string, unknown>;
    const output = fields.output;
    const enabled = fields.enabled;
    if (typeof output !== "string" || typeof enabled !== "boolean") {
      throw new Error(`Manifest ${path}: config "${key}" needs string "output" and boolean "enabled"`);
    }
    enabledByOutput.set(output, enabled);
  }

  return enabledByOutput;
}

async function applyTarget(target: ConfigTarget, options: Options): Promise<"updated" | "skipped"> {
  const targetPaths = target.targetRels.map((rel) => join(options.baseHome, rel));
  const targetPath = await firstExisting(targetPaths);
  if (targetPath === undefined) {
    process.stdout.write(`${target.name}: skipped; no config found\n`);
    return "skipped";
  }

  const generatedPath = join(options.generatedRoot, target.generatedRel);
  if (!(await pathExists(generatedPath))) {
    throw new Error(`${target.name}: generated config does not exist: ${generatedPath}`);
  }

  const current = parseJsonc(await readFile(targetPath, "utf8"), targetPath);
  const generated = parseJsonc(await readFile(generatedPath, "utf8"), generatedPath);
  const merged = target.merge(current, generated);

  if (options.dryRun) {
    process.stdout.write(`${target.name}: dry-run merge ok -> ${targetPath}\n`);
    return "updated";
  }

  await mkdir(dirname(targetPath), { recursive: true });
  await writeFile(targetPath, formatJson(merged));
  process.stdout.write(`${target.name}: updated ${targetPath}\n`);
  return "updated";
}

async function main(): Promise<void> {
  const options = parseArgs(Bun.argv.slice(2));
  const enabledOutputs = await loadEnabledOutputs(options.manifest);
  let updated = 0;
  let skipped = 0;

  for (const target of TARGETS) {
    const enabled = enabledOutputs.get(target.generatedRel);
    if (enabled === false) {
      process.stdout.write(`${target.name}: skipped; disabled in manifest\n`);
      skipped += 1;
      continue;
    }
    if (enabled === undefined) {
      process.stdout.write(`${target.name}: not declared in manifest; assuming enabled\n`);
    }
    const result = await applyTarget(target, options);
    if (result === "updated") {
      updated += 1;
    } else {
      skipped += 1;
    }
  }

  const dryRunText = options.dryRun ? " dry-run" : "";
  process.stdout.write(`update-user-configs:${dryRunText} ${updated} updated, ${skipped} skipped\n`);
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`update-user-configs: ${message}\n`);
  process.exit(1);
});
