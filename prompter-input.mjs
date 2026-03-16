#!/usr/bin/env node
import { writeFile } from "node:fs/promises";
import { captureInputOnce, FailClosedError } from "./prompterInputCore.mjs";

const EXIT_CODES = {
  SUBMIT: 0,
  QUIT: 20,
  HELP: 21,
  RESET: 22,
  FAIL_CLOSED: 23,
  SETTINGS: 24,
  DISCOVER: 26,
  ERROR: 1,
};

function parseArgs(argv) {
  const options = {
    output: "",
    idleMs: 250,
    pasteTimeoutMs: 30000,
    maxBytes: 2_000_000,
    prompt: "prompter> ",
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--output") {
      options.output = argv[i + 1] ?? "";
      i += 1;
      continue;
    }
    if (arg === "--idle-ms") {
      options.idleMs = Number(argv[i + 1] ?? options.idleMs);
      i += 1;
      continue;
    }
    if (arg === "--paste-timeout-ms") {
      options.pasteTimeoutMs = Number(argv[i + 1] ?? options.pasteTimeoutMs);
      i += 1;
      continue;
    }
    if (arg === "--max-bytes") {
      options.maxBytes = Number(argv[i + 1] ?? options.maxBytes);
      i += 1;
      continue;
    }
    if (arg === "--prompt") {
      options.prompt = argv[i + 1] ?? options.prompt;
      i += 1;
    }
  }

  return options;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));

  if (!options.output) {
    console.error("prompter-input: --output <file> is required.");
    process.exit(EXIT_CODES.ERROR);
  }

  try {
    const result = await captureInputOnce({
      stdin: process.stdin,
      stdout: process.stdout,
      prompt: options.prompt,
      idleSubmitMs: options.idleMs,
      pasteTimeoutMs: options.pasteTimeoutMs,
      maxBytes: options.maxBytes,
    });

    if (result.type === "submit") {
      await writeFile(options.output, result.text, "utf8");
      process.exit(EXIT_CODES.SUBMIT);
    }

    if (result.type === "quit") {
      process.exit(EXIT_CODES.QUIT);
    }

    if (result.type === "help") {
      process.exit(EXIT_CODES.HELP);
    }

    if (result.type === "reset") {
      process.exit(EXIT_CODES.RESET);
    }

    if (result.type === "settings") {
      process.exit(EXIT_CODES.SETTINGS);
    }


    if (result.type === "discover") {
      process.exit(EXIT_CODES.DISCOVER);
    }

    process.exit(EXIT_CODES.ERROR);
  } catch (err) {
    if (err instanceof FailClosedError) {
      console.error(`\nInteractive capture unavailable: ${err.message}`);
      console.error("Use one-shot input or pipe from stdin instead.");
      process.exit(EXIT_CODES.FAIL_CLOSED);
    }

    console.error(`\nInteractive capture failed: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(EXIT_CODES.ERROR);
  }
}

void main();
