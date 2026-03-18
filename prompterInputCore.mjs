import { BracketedPasteParser } from "./prompterInputParser.mjs";

const ENTER_ESC_O_M = Buffer.from([0x1b, 0x4f, 0x4d]); // ESC O M
const ENTER_ESC_13_TILDE = Buffer.from([0x1b, 0x5b, 0x31, 0x33, 0x7e]); // ESC [ 13 ~

const SLASH_COMMANDS = [
  { cmd: "/help", desc: "Show help" },
  { cmd: "/settings", desc: "Configure agent & model" },
  { cmd: "/experts", desc: "List discovered expertise categories" },
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

// ---------------------------------------------------------------------------
// Paste-block helpers
// ---------------------------------------------------------------------------

// Find the start index of the paste block that the entry at `pos - 1` belongs to.
function pasteBlockStart(entries, pos) {
  let i = pos - 1;
  while (i > 0 && entries[i - 1].source === "paste") {
    i -= 1;
  }
  return i;
}

// Find the end index (exclusive) of the paste block that the entry at `pos` belongs to.
function pasteBlockEnd(entries, pos) {
  let i = pos;
  while (i < entries.length && entries[i].source === "paste") {
    i += 1;
  }
  return i;
}

// ---------------------------------------------------------------------------
// Word-boundary helpers (for Option+Arrow)
// ---------------------------------------------------------------------------

// Move cursor left by one word. Skips whitespace then stops at start of word.
// Paste blocks are treated as a single unit.
function wordLeft(entries, cursorPos) {
  if (cursorPos <= 0) {
    return 0;
  }

  // If cursor is at the end of a paste block, jump to start of that block.
  if (entries[cursorPos - 1].source === "paste") {
    return pasteBlockStart(entries, cursorPos);
  }

  let pos = cursorPos;
  // Skip whitespace
  while (pos > 0 && entries[pos - 1].source === "typing" && entries[pos - 1].ch === " ") {
    pos -= 1;
  }
  // Skip word characters
  while (pos > 0 && entries[pos - 1].source === "typing" && entries[pos - 1].ch !== " ") {
    pos -= 1;
  }
  return pos;
}

// Move cursor right by one word. Skips word then whitespace.
// Paste blocks are treated as a single unit.
function wordRight(entries, cursorPos) {
  if (cursorPos >= entries.length) {
    return entries.length;
  }

  // If cursor is at the start of a paste block, jump to end of that block.
  if (entries[cursorPos].source === "paste") {
    return pasteBlockEnd(entries, cursorPos);
  }

  let pos = cursorPos;
  // Skip word characters
  while (pos < entries.length && entries[pos].source === "typing" && entries[pos].ch !== " ") {
    pos += 1;
  }
  // Skip whitespace
  while (pos < entries.length && entries[pos].source === "typing" && entries[pos].ch === " ") {
    pos += 1;
  }
  return pos;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Renders the display string and computes the display-column offset of the cursor.
function renderInputDisplayWithCursor(entries, cursorPos) {
  if (entries.length === 0) {
    return { display: "", cursorDisplayOffset: 0 };
  }

  let out = "";
  let cursorDisplayOffset = 0;
  let cursorSet = false;
  let index = 0;

  while (index < entries.length) {
    if (index === cursorPos && !cursorSet) {
      cursorDisplayOffset = out.length;
      cursorSet = true;
    }

    const entry = entries[index];

    if (entry.source === "typing") {
      out += entry.ch;
      index += 1;
      continue;
    }

    // Paste block
    let segmentChars = 0;
    let segmentLines = 1;
    const blockStart = index;
    while (index < entries.length && entries[index].source === "paste") {
      segmentChars += 1;
      if (entries[index].ch === "\n") {
        segmentLines += 1;
      }
      index += 1;
    }

    const label = `[pasted ${segmentChars} characters across ${normalizeLineCount(segmentLines)} lines]`;
    // If cursor is inside this paste block, place it at the start of the label
    if (!cursorSet && cursorPos >= blockStart && cursorPos < index) {
      cursorDisplayOffset = out.length;
      cursorSet = true;
    }
    out += label;
  }

  // Cursor at the very end
  if (!cursorSet) {
    cursorDisplayOffset = out.length;
  }

  return { display: out, cursorDisplayOffset };
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

// ---------------------------------------------------------------------------
// Escape sequence detection
// ---------------------------------------------------------------------------

// Known escape sequences we handle (beyond bracketed paste which the parser handles):
//   Arrow Left:        ESC [ D           (0x1b 0x5b 0x44)
//   Arrow Right:       ESC [ C           (0x1b 0x5b 0x43)
//   Option+Left:       ESC b             (0x1b 0x62)     — or ESC [ 1;3 D
//   Option+Right:      ESC f             (0x1b 0x66)     — or ESC [ 1;3 C
//   Option+Backspace:  ESC DEL           (0x1b 0x7f)
//
// Returns: { action, consumed } or null if not a known sequence.
function matchEscapeSequence(bytes, offset) {
  const remaining = bytes.length - offset;
  if (remaining < 2 || bytes[offset] !== 0x1b) {
    return null;
  }

  const b1 = bytes[offset + 1];

  // ESC b — Option+Left (word left)
  if (b1 === 0x62) {
    return { action: "word-left", consumed: 2 };
  }
  // ESC f — Option+Right (word right)
  if (b1 === 0x66) {
    return { action: "word-right", consumed: 2 };
  }
  // ESC DEL — Option+Backspace (delete word)
  if (b1 === 0x7f) {
    return { action: "delete-word", consumed: 2 };
  }

  // ESC [ sequences
  if (b1 === 0x5b && remaining >= 3) {
    const b2 = bytes[offset + 2];

    // ESC [ D — Arrow Left
    if (b2 === 0x44) {
      return { action: "left", consumed: 3 };
    }
    // ESC [ C — Arrow Right
    if (b2 === 0x43) {
      return { action: "right", consumed: 3 };
    }

    // ESC [ 1 ; 3 D — Option+Arrow Left (modifier 3 = Alt/Option)
    // ESC [ 1 ; 3 C — Option+Arrow Right
    if (remaining >= 6 && b2 === 0x31 && bytes[offset + 3] === 0x3b && bytes[offset + 4] === 0x33) {
      const dir = bytes[offset + 5];
      if (dir === 0x44) {
        return { action: "word-left", consumed: 6 };
      }
      if (dir === 0x43) {
        return { action: "word-right", consumed: 6 };
      }
    }
  }

  return null;
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
  let cursorPos = 0; // index into inputEntries where the cursor sits
  let pasteTimeoutTimer = null;
  let submitTokenPending = Buffer.alloc(0);
  let lastRenderedLineCount = 1;
  let escBuf = Buffer.alloc(0); // buffer for split navigation escape sequences
  let escTimer = null; // timeout to flush incomplete escape sequences

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
    const { display, cursorDisplayOffset } = renderInputDisplayWithCursor(inputEntries, cursorPos);
    const line = `${prompt}${display}`;
    const cols = getTerminalColumns();
    const newLineCount = Math.max(1, Math.ceil(line.length / cols));

    // Move cursor up to the start of the previous input line(s) and clear.
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
        // Move cursor back up to input line
        output += `\u001b[${suggestions.length}A`;
      }
    }

    // Position terminal cursor at the correct column for cursorPos
    const cursorCol = prompt.length + cursorDisplayOffset;
    const cursorRow = Math.floor(cursorCol / cols);
    const cursorColInRow = (cursorCol % cols) + 1; // 1-based

    // Move to start of line area, then down to cursor row, then to cursor column
    // We're currently at the end of the output, so reposition from line start
    const totalRows = newLineCount - 1;
    if (totalRows > cursorRow) {
      output += `\u001b[${totalRows - cursorRow}A`;
    }
    output += `\r\u001b[${cursorColInRow}G`;

    stdout.write(output);
    lastRenderedLineCount = newLineCount;
  };

  const appendByteAt = (byte, source, pos) => {
    if (byte === 0x0d) {
      return;
    }

    if (byte < 0x20 && byte !== 0x09 && byte !== 0x0a) {
      return;
    }

    const entry = { ch: String.fromCharCode(byte), source };
    inputEntries.splice(pos, 0, entry);
    cursorPos = pos + 1;

    if (Buffer.byteLength(decodeEntries(inputEntries), "utf8") > maxBytes) {
      throw new FailClosedError(`Input exceeded maximum size (${maxBytes} bytes).`);
    }
  };

  const decodeForSubmit = () => sanitizeCapturedText(decodeEntries(inputEntries));

  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearPasteTimeoutTimer();
      if (escTimer) { clearTimeout(escTimer); escTimer = null; }
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
      try {
        stdout.write("\u001b[J");
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
        cursorPos = 0;
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
        if (command === "/experts") {
          finish({ type: "experts" });
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

    const handleAction = (action) => {
      switch (action) {
        case "left":
          if (cursorPos > 0) {
            // Skip over entire paste block if stepping into one
            if (inputEntries[cursorPos - 1].source === "paste") {
              cursorPos = pasteBlockStart(inputEntries, cursorPos);
            } else {
              cursorPos -= 1;
            }
          }
          writePromptStatus();
          return true;

        case "right":
          if (cursorPos < inputEntries.length) {
            // Skip over entire paste block if stepping into one
            if (inputEntries[cursorPos].source === "paste") {
              cursorPos = pasteBlockEnd(inputEntries, cursorPos);
            } else {
              cursorPos += 1;
            }
          }
          writePromptStatus();
          return true;

        case "word-left":
          cursorPos = wordLeft(inputEntries, cursorPos);
          writePromptStatus();
          return true;

        case "word-right":
          cursorPos = wordRight(inputEntries, cursorPos);
          writePromptStatus();
          return true;

        case "delete-word": {
          // Option+Backspace: delete from cursor back to word boundary
          if (cursorPos <= 0) {
            return true;
          }
          const target = wordLeft(inputEntries, cursorPos);
          inputEntries.splice(target, cursorPos - target);
          cursorPos = target;
          writePromptStatus();
          return true;
        }

        default:
          return false;
      }
    };

    const processByte = (byte, inPaste) => {
      if (inPaste) {
        // Paste always appends at end
        appendByteAt(byte, "paste", inputEntries.length);
        cursorPos = inputEntries.length;
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
        cursorPos = 0;
        writePromptStatus();
        return;
      }

      if (byte === 0x01) {
        // Ctrl+A — move to start
        cursorPos = 0;
        writePromptStatus();
        return;
      }

      if (byte === 0x05) {
        // Ctrl+E — move to end
        cursorPos = inputEntries.length;
        writePromptStatus();
        return;
      }

      if (byte === 0x7f || byte === 0x08) {
        // Backspace — delete at cursor position
        if (cursorPos <= 0) {
          return;
        }
        // If the entry before cursor is part of a paste block, delete the entire block
        if (inputEntries[cursorPos - 1].source === "paste") {
          const blockStart = pasteBlockStart(inputEntries, cursorPos);
          inputEntries.splice(blockStart, cursorPos - blockStart);
          cursorPos = blockStart;
        } else {
          cursorPos -= 1;
          inputEntries.splice(cursorPos, 1);
        }
        writePromptStatus();
        return;
      }

      if (byte === 0x09) {
        // Tab — autocomplete slash commands
        const currentText = decodeEntries(inputEntries);
        const matches = matchingCommands(currentText);
        if (matches.length === 1) {
          inputEntries.length = 0;
          const completion = matches[0].cmd;
          for (const ch of completion) {
            inputEntries.push({ ch, source: "typing" });
          }
          cursorPos = inputEntries.length;
        } else if (matches.length > 1) {
          const cp = commonPrefix(matches.map((m) => m.cmd));
          if (cp.length > currentText.length) {
            inputEntries.length = 0;
            for (const ch of cp) {
              inputEntries.push({ ch, source: "typing" });
            }
            cursorPos = inputEntries.length;
          }
        }
        writePromptStatus();
        return;
      }

      if (isPrintableByte(byte)) {
        appendByteAt(byte, "typing", cursorPos);
      }
    };

    const onData = (chunk) => {
      if (done) {
        return;
      }

      try {
        const rawChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);

        // Check for navigation escape sequences before the normal pipeline (only outside paste).
        // We only intercept sequences we handle (arrow keys, Option+arrow, Option+backspace)
        // and let everything else (ESC O M submit, bracketed paste markers, etc.) through.
        if (!parser.inPaste) {
          // Clear any pending ESC flush timer since we got more data
          if (escTimer) {
            clearTimeout(escTimer);
            escTimer = null;
          }

          const combined = escBuf.length > 0 ? Buffer.concat([escBuf, rawChunk]) : rawChunk;
          escBuf = Buffer.alloc(0);

          // Scan for navigation escape sequences, splitting the buffer into
          // "pass-through" segments and "handled" actions.
          const passThrough = [];
          let segStart = 0;
          let i = 0;

          while (i < combined.length) {
            if (combined[i] === 0x1b) {
              const seq = matchEscapeSequence(combined, i);
              if (seq) {
                // Flush any bytes before this sequence to the normal pipeline
                if (i > segStart) {
                  passThrough.push(combined.subarray(segStart, i));
                }
                handleAction(seq.action);
                i += seq.consumed;
                segStart = i;
                continue;
              }
              // Lone ESC at the end — buffer it and wait for more bytes
              const remainingBytes = combined.length - i;
              if (remainingBytes < 6) {
                // Flush everything before the ESC
                if (i > segStart) {
                  passThrough.push(combined.subarray(segStart, i));
                }
                escBuf = Buffer.from(combined.subarray(i));
                // Set a short timeout — if nothing follows, flush as regular bytes
                escTimer = setTimeout(() => {
                  escTimer = null;
                  if (escBuf.length > 0 && !done) {
                    const pending = escBuf;
                    escBuf = Buffer.alloc(0);
                    processRawBytes(pending);
                    if (!done && !parser.inPaste) {
                      writePromptStatus();
                    }
                  }
                }, 50);
                // Process anything we collected before the ESC
                for (const seg of passThrough) {
                  if (!done) {
                    processRawBytes(seg);
                  }
                }
                return;
              }
            }
            i += 1;
          }

          // Remaining bytes go through the normal pipeline
          if (segStart < combined.length) {
            passThrough.push(combined.subarray(segStart));
          }

          for (const seg of passThrough) {
            if (!done) {
              processRawBytes(seg);
            }
          }
          return;
        }

        // Inside paste — go through normal pipeline
        processRawBytes(rawChunk);
      } catch (err) {
        if (err instanceof FailClosedError) {
          resetCapture(err.message);
          return;
        }
        onError(err);
      }
    };

    const processRawBytes = (rawChunk) => {
      const rawBytes =
        submitTokenPending.length > 0 ? Buffer.concat([submitTokenPending, rawChunk]) : rawChunk;

      const stripped = stripTrailingSubmitTokens(rawBytes);

      let bytes;
      let sawSubmit;
      if (parser.inPaste) {
        sawSubmit = stripped.sawSubmit;
        if (sawSubmit && stripped.payload.length === 0) {
          clearPasteTimeoutTimer();
          parser.reset();
          writePromptStatus();
          submitInput();
          return;
        }
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

      const events = parser.feed(bytes);

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
          continue;
        }

        if (event.type === "byte") {
          if (looksLikeUnbracketedPaste && !event.inPaste) {
            appendByteAt(event.byte, "paste", inputEntries.length);
            cursorPos = inputEntries.length;
          } else {
            processByte(event.byte, event.inPaste);
          }
        }
      }

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

      if (!done && !parser.inPaste) {
        writePromptStatus();
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
