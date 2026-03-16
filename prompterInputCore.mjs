import { BracketedPasteParser } from "./prompterInputParser.mjs";

const ENTER_ESC_O_M = Buffer.from([0x1b, 0x4f, 0x4d]); // ESC O M
const ENTER_ESC_13_TILDE = Buffer.from([0x1b, 0x5b, 0x31, 0x33, 0x7e]); // ESC [ 13 ~

const SLASH_COMMANDS = [
  { cmd: "/help", desc: "Show help" },
  { cmd: "/settings", desc: "Configure agent & model" },
  { cmd: "/workspace", desc: "Change workspace directory" },
  { cmd: "/discover", desc: "Re-discover expertise categories" },
  { cmd: "/quit", desc: "Exit" },
];

export class FailClosedError extends Error {
  constructor(message) {
    super(message);
    this.name = "FailClosedError";
  }
}

function isPrintableByte(byte) {
  return byte >= 0x20 && byte <= 0x7e;
}

function sanitizeCapturedText(text) {
  return text
    .replace(/\r/g, "")
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
}

function lineCountFor(text) {
  if (text.length === 0) {
    return 0;
  }
  return text.split("\n").length;
}

function normalizeLineCount(count) {
  return count > 0 ? count : 1;
}

function decodeEntries(entries) {
  return entries.map((entry) => entry.ch).join("");
}

function hasPaste(entries) {
  return entries.some((entry) => entry.source === "paste");
}

function removeLastCharacter(entries) {
  if (entries.length === 0) {
    return;
  }
  entries.pop();
}

function entriesEndWith(entries, suffix) {
  if (entries.length < suffix.length) {
    return false;
  }
  const start = entries.length - suffix.length;
  for (let i = 0; i < suffix.length; i += 1) {
    if (entries[start + i].ch !== suffix[i]) {
      return false;
    }
  }
  return true;
}

function popTrailingEnterEscapeToken(entries) {
  const escOM = "\u001bOM";
  const esc13Tilde = "\u001b[13~";

  if (entriesEndWith(entries, esc13Tilde)) {
    entries.splice(entries.length - esc13Tilde.length, esc13Tilde.length);
    return true;
  }

  if (entriesEndWith(entries, escOM)) {
    entries.splice(entries.length - escOM.length, escOM.length);
    return true;
  }

  return false;
}

function matchingCommands(text) {
  if (!text.startsWith("/") || text.includes(" ")) {
    return [];
  }
  const prefix = text.toLowerCase();
  return SLASH_COMMANDS.filter((c) => c.cmd.toLowerCase().startsWith(prefix));
}

function commonPrefix(strings) {
  if (strings.length === 0) {
    return "";
  }
  let prefix = strings[0];
  for (let i = 1; i < strings.length; i += 1) {
    while (!strings[i].startsWith(prefix)) {
      prefix = prefix.slice(0, -1);
    }
  }
  return prefix;
}

function renderInputDisplay(entries) {
  if (entries.length === 0) {
    return "";
  }

  let out = "";
  let index = 0;

  while (index < entries.length) {
    const entry = entries[index];

    if (entry.source === "typing") {
      out += entry.ch;
      index += 1;
      continue;
    }

    let segmentChars = 0;
    let segmentLines = 1;
    while (index < entries.length && entries[index].source === "paste") {
      segmentChars += 1;
      if (entries[index].ch === "\n") {
        segmentLines += 1;
      }
      index += 1;
    }

    out += `[pasted ${segmentChars} characters across ${normalizeLineCount(segmentLines)} lines]`;
  }

  return out;
}

function stripTrailingSubmitTokens(bytes) {
  let end = bytes.length;
  let sawSubmit = false;
  let changed = true;

  while (changed && end > 0) {
    changed = false;

    if (
      end >= ENTER_ESC_13_TILDE.length &&
      bytes.subarray(end - ENTER_ESC_13_TILDE.length, end).equals(ENTER_ESC_13_TILDE)
    ) {
      end -= ENTER_ESC_13_TILDE.length;
      sawSubmit = true;
      changed = true;
      continue;
    }

    if (end >= ENTER_ESC_O_M.length && bytes.subarray(end - ENTER_ESC_O_M.length, end).equals(ENTER_ESC_O_M)) {
      end -= ENTER_ESC_O_M.length;
      sawSubmit = true;
      changed = true;
      continue;
    }

    const byte = bytes[end - 1];
    if (byte === 0x0a || byte === 0x0d) {
      end -= 1;
      sawSubmit = true;
      changed = true;
    }
  }

  return {
    payload: bytes.subarray(0, end),
    sawSubmit,
  };
}

function isPrefix(candidate, seq) {
  if (candidate.length > seq.length) {
    return false;
  }
  for (let i = 0; i < candidate.length; i += 1) {
    if (candidate[i] !== seq[i]) {
      return false;
    }
  }
  return true;
}

function computeSubmitTokenPendingSuffix(bytes) {
  const maxLen = Math.min(bytes.length, ENTER_ESC_13_TILDE.length - 1);
  for (let len = maxLen; len >= 1; len -= 1) {
    const tail = bytes.subarray(bytes.length - len);
    if (isPrefix(tail, ENTER_ESC_O_M) || isPrefix(tail, ENTER_ESC_13_TILDE)) {
      return tail;
    }
  }
  return Buffer.alloc(0);
}

export async function captureInputOnce({
  stdin,
  stdout,
  prompt = "prompter> ",
  pasteTimeoutMs = 30000,
  maxBytes = 2_000_000,
} = {}) {
  if (!stdin || !stdout) {
    throw new FailClosedError("Missing stdin/stdout streams.");
  }

  if (!stdin.isTTY || !stdout.isTTY) {
    throw new FailClosedError("Interactive capture requires a TTY.");
  }

  if (typeof stdin.setRawMode !== "function") {
    throw new FailClosedError("Interactive capture requires raw-mode support.");
  }

  const parser = new BracketedPasteParser();

  let done = false;
  const inputEntries = [];
  let pasteTimeoutTimer = null;
  let submitTokenPending = Buffer.alloc(0);
  let lastRenderedLineCount = 1;

  const clearPasteTimeoutTimer = () => {
    if (pasteTimeoutTimer) {
      clearTimeout(pasteTimeoutTimer);
      pasteTimeoutTimer = null;
    }
  };

  const getTerminalColumns = () => {
    if (stdout.columns && stdout.columns > 0) {
      return stdout.columns;
    }
    return 80;
  };

  const writePromptStatus = () => {
    const display = renderInputDisplay(inputEntries);
    const line = `${prompt}${display}`;
    const cols = getTerminalColumns();
    const newLineCount = Math.max(1, Math.ceil(line.length / cols));

    // Move cursor up to the start of the previous input line(s) and clear.
    // lastRenderedLineCount tracks only the input line wrapping, not suggestions.
    let clearSeq = "";
    if (lastRenderedLineCount > 1) {
      clearSeq += `\u001b[${lastRenderedLineCount - 1}A`;
    }
    clearSeq += "\r";
    for (let i = 0; i < lastRenderedLineCount; i += 1) {
      clearSeq += "\u001b[2K";
      if (i < lastRenderedLineCount - 1) {
        clearSeq += "\u001b[1B";
      }
    }
    if (lastRenderedLineCount > 1) {
      clearSeq += `\u001b[${lastRenderedLineCount - 1}A`;
    }
    clearSeq += "\r";

    // Write input line, then erase everything below (old suggestions)
    let output = `${clearSeq}${line}\u001b[J`;

    // Build and render suggestion lines for slash commands
    const currentText = decodeEntries(inputEntries);
    if (!hasPaste(inputEntries)) {
      const matches = matchingCommands(currentText);
      if (matches.length > 0 && !(matches.length === 1 && matches[0].cmd === currentText)) {
        const typed = currentText.length;
        const suggestions = matches.map((m) => {
          const highlighted =
            `\u001b[33m${m.cmd.slice(0, typed)}\u001b[0m${m.cmd.slice(typed)}`;
          return `  ${highlighted}  \u001b[2m${m.desc}\u001b[0m`;
        });
        output += "\n" + suggestions.join("\n");
        // Move cursor back up to end of input line
        output += `\u001b[${suggestions.length}A`;
        const endCol = line.length % cols || cols;
        output += `\u001b[${endCol}G`;
      }
    }

    stdout.write(output);
    // Only track input line count — suggestions are wiped by ESC[J each redraw
    lastRenderedLineCount = newLineCount;
  };

  const appendByte = (byte, source) => {
    if (byte === 0x0d) {
      return;
    }

    if (byte < 0x20 && byte !== 0x09 && byte !== 0x0a) {
      return;
    }

    inputEntries.push({
      ch: String.fromCharCode(byte),
      source,
    });

    if (Buffer.byteLength(decodeEntries(inputEntries), "utf8") > maxBytes) {
      throw new FailClosedError(`Input exceeded maximum size (${maxBytes} bytes).`);
    }
  };

  const decodeForSubmit = () => sanitizeCapturedText(decodeEntries(inputEntries));

  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearPasteTimeoutTimer();
      stdin.removeListener("data", onData);
      stdin.removeListener("error", onError);
      try {
        stdout.write("\u001b[?2004l");
      } catch {
        // no-op
      }
      try {
        stdin.setRawMode(false);
      } catch {
        // no-op
      }
      try {
        stdin.pause();
      } catch {
        // no-op
      }
    };

    const clearBelowCursor = () => {
      // Clear any suggestion lines rendered below the current cursor position
      try {
        stdout.write("\u001b[J"); // ESC[J — erase from cursor to end of screen
      } catch {
        // no-op
      }
    };

    const finish = (result) => {
      if (done) {
        return;
      }
      done = true;
      cleanup();
      clearBelowCursor();
      stdout.write(`\n${separator}\n`);
      resolve(result);
    };

    const resetCapture = (reason) => {
      if (done) {
        return;
      }
      done = true;
      cleanup();
      stdout.write(`\r\u001b[2K${prompt}[input reset: ${reason}]\n`);
      resolve({ type: "reset", reason });
    };

    const submitInput = () => {
      const submitted = decodeForSubmit();
      if (submitted.trim().length === 0) {
        inputEntries.length = 0;
        parser.reset();
        writePromptStatus();
        return;
      }

      const lines = lineCountFor(submitted);
      if (!hasPaste(inputEntries) && lines === 1) {
        const command = submitted.trim();
        if (command === "/quit" || command === "quit" || command === "exit") {
          finish({ type: "quit" });
          return;
        }
        if (command === "/help") {
          finish({ type: "help" });
          return;
        }
        if (command === "/settings") {
          finish({ type: "settings" });
          return;
        }
        if (command === "/workspace" || command.startsWith("/workspace ")) {
          const arg = command.slice("/workspace".length).trim();
          finish({ type: "workspace", text: arg });
          return;
        }
        if (command === "/discover") {
          finish({ type: "discover" });
          return;
        }
      }

      finish({
        type: "submit",
        text: submitted,
        chars: submitted.length,
        lines,
      });
    };

    const startPasteTimeout = () => {
      clearPasteTimeoutTimer();
      pasteTimeoutTimer = setTimeout(() => {
        resetCapture(`unterminated paste exceeded ${pasteTimeoutMs}ms timeout`);
      }, pasteTimeoutMs);
    };

    const onError = (err) => {
      if (done) {
        return;
      }
      done = true;
      cleanup();
      reject(err);
    };

    const processByte = (byte, inPaste) => {
      if (inPaste) {
        appendByte(byte, "paste");
        return;
      }

      if (byte === 0x03) {
        finish({ type: "quit" });
        return;
      }

      if (byte === 0x0d || byte === 0x0a) {
        submitInput();
        return;
      }

      if (byte === 0x15) {
        // Ctrl+U — clear entire input.
        inputEntries.length = 0;
        writePromptStatus();
        return;
      }

      if (byte === 0x7f || byte === 0x08) {
        removeLastCharacter(inputEntries);
        writePromptStatus();
        return;
      }

      if (byte === 0x09) {
        // Tab — autocomplete slash commands
        const currentText = decodeEntries(inputEntries);
        const matches = matchingCommands(currentText);
        if (matches.length === 1) {
          // Single match — complete it
          inputEntries.length = 0;
          const completion = matches[0].cmd;
          for (const ch of completion) {
            inputEntries.push({ ch, source: "typing" });
          }
          // Add trailing space for commands that accept args
          if (matches[0].cmd === "/workspace") {
            inputEntries.push({ ch: " ", source: "typing" });
          }
        } else if (matches.length > 1) {
          // Multiple matches — complete common prefix
          const cp = commonPrefix(matches.map((m) => m.cmd));
          if (cp.length > currentText.length) {
            inputEntries.length = 0;
            for (const ch of cp) {
              inputEntries.push({ ch, source: "typing" });
            }
          }
        }
        writePromptStatus();
        return;
      }

      if (isPrintableByte(byte)) {
        appendByte(byte, "typing");
      }
    };

    const onData = (chunk) => {
      if (done) {
        return;
      }

      try {
        const rawChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        const rawBytes =
          submitTokenPending.length > 0 ? Buffer.concat([submitTokenPending, rawChunk]) : rawChunk;

        const stripped = stripTrailingSubmitTokens(rawBytes);

        // During an active bracketed paste, trailing \n / \r are paste
        // content, not submit signals.  ESC O M / ESC [ 13 ~ are always
        // submit signals regardless of paste state.
        let bytes;
        let sawSubmit;
        if (parser.inPaste) {
          sawSubmit = stripped.sawSubmit;
          if (sawSubmit && stripped.payload.length === 0) {
            // Whole chunk was just Enter / ESC O M — force-submit.
            clearPasteTimeoutTimer();
            parser.reset();
            writePromptStatus();
            submitInput();
            return;
          }
          // Content chunk during paste — feed raw bytes so trailing \n / \r
          // are preserved as paste content.  But still track partial escape
          // sequences (ESC O M split across chunks) via submitTokenPending.
          submitTokenPending = computeSubmitTokenPendingSuffix(rawBytes);
          bytes =
            submitTokenPending.length > 0
              ? rawBytes.subarray(0, rawBytes.length - submitTokenPending.length)
              : rawBytes;
          sawSubmit = false;
        } else {
          submitTokenPending = computeSubmitTokenPendingSuffix(stripped.payload);
          bytes =
            submitTokenPending.length > 0
              ? stripped.payload.subarray(0, stripped.payload.length - submitTokenPending.length)
              : stripped.payload;
          sawSubmit = stripped.sawSubmit;
        }

        // Parse first so bracketed paste markers are detected before the
        // unbracketed-paste heuristic runs.  This prevents a single chunk
        // containing both markers AND newlines from being misclassified.
        const events = parser.feed(bytes);

        // Fail-safe: some terminals don't emit bracketed markers for paste.
        // After parsing, check whether the non-paste bytes look like a burst
        // and reclassify them so embedded newlines don't trigger submission.
        const nonPasteBytes = events.filter((e) => e.type === "byte" && !e.inPaste);
        const nonPasteNewlineCount = nonPasteBytes.reduce(
          (count, e) => (e.byte === 0x0a || e.byte === 0x0d ? count + 1 : count),
          0,
        );
        const looksLikeUnbracketedPaste =
          nonPasteBytes.length > 0 &&
          (nonPasteNewlineCount >= 2 ||
            (nonPasteNewlineCount >= 1 && nonPasteBytes.length > 128) ||
            nonPasteBytes.length > 512);

        let pasteEndSeen = false;
        for (const event of events) {
          if (done) {
            return;
          }

          if (event.type === "paste_start") {
            startPasteTimeout();
            continue;
          }

          if (event.type === "paste_end") {
            clearPasteTimeoutTimer();
            pasteEndSeen = true;
            continue;
          }

          if (event.type === "byte") {
            if (looksLikeUnbracketedPaste && !event.inPaste) {
              appendByte(event.byte, "paste");
            } else {
              processByte(event.byte, event.inPaste);
            }
          }
        }

        // Fallback for split enter escape sequences (e.g. ESC O M arriving
        // across multiple chunks) that were ingested as regular bytes.
        if (!done && popTrailingEnterEscapeToken(inputEntries)) {
          if (parser.inPaste) {
            clearPasteTimeoutTimer();
            parser.reset();
          }
          submitInput();
          return;
        }

        if (!done && sawSubmit && !parser.inPaste) {
          submitInput();
          return;
        }

        // Only redraw when NOT mid-paste.  During an active bracketed paste
        // the character count would change on every chunk, flooding the
        // terminal with redraws that stack up as wrapped-line ghosts.
        // Redraw once the paste_end marker arrives or when typing normally.
        if (!done && !parser.inPaste) {
          writePromptStatus();
        }
      } catch (err) {
        if (err instanceof FailClosedError) {
          resetCapture(err.message);
          return;
        }
        onError(err);
      }
    };

    const separator = "\u001b[2m" + "─".repeat(60) + "\u001b[0m";

    try {
      stdin.setRawMode(true);
      stdin.resume();
      stdout.write("\u001b[?2004h");
      stdout.write(`\n${separator}\n${prompt}`);
    } catch {
      cleanup();
      reject(new FailClosedError("Failed to initialize interactive raw-mode capture."));
      return;
    }

    stdin.on("data", onData);
    stdin.on("error", onError);
  });
}
