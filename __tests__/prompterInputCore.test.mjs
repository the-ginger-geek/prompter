import { EventEmitter } from "node:events";
import test from "node:test";
import assert from "node:assert/strict";

import {
  FailClosedError,
  captureInputOnce,
} from "../prompterInputCore.mjs";
import {
  BRACKETED_PASTE_END,
  BRACKETED_PASTE_START,
} from "../prompterInputParser.mjs";

class FakeTTYInput extends EventEmitter {
  constructor() {
    super();
    this.isTTY = true;
    this.rawMode = false;
  }

  setRawMode(flag) {
    this.rawMode = flag;
  }

  resume() {}

  pause() {}

  sendBytes(bytes) {
    this.emit("data", Buffer.from(bytes));
  }
}

class FakeTTYOutput {
  constructor() {
    this.isTTY = true;
    this.columns = 120;
    this.buffer = "";
  }

  write(chunk) {
    const text = Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
    this.buffer += text;
    return true;
  }
}

test("captureInputOnce submits bracketed paste without echoing payload", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
    maxBytes: 100_000,
  });

  stdin.sendBytes(BRACKETED_PASTE_START);
  stdin.sendBytes(Buffer.from('{"msg":"line1"}\nline2', "utf8"));
  stdin.sendBytes(BRACKETED_PASTE_END);
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;

  assert.equal(result.type, "submit");
  assert.equal(result.text, '{"msg":"line1"}\nline2');
  assert.match(stdout.buffer, /\[pasted \d+ characters across 2 lines\]/);
  assert.equal(stdout.buffer.includes('{"msg":"line1"}'), false);
});

test("captureInputOnce handles typing with backspace and submit", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(Buffer.from("abc", "utf8"));
  stdin.sendBytes(Buffer.from([0x7f])); // backspace
  stdin.sendBytes(Buffer.from("d", "utf8"));
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;

  assert.equal(result.type, "submit");
  assert.equal(result.text, "abd");
  assert.equal(stdout.buffer.includes("prompter> abd"), true);
});

test("captureInputOnce treats large unbracketed multiline chunks as paste", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(
    Buffer.from(
      "[out] a line that is long enough to look like paste\n[out] second line\n[out] third line",
      "utf8",
    ),
  );
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.match(stdout.buffer, /\[pasted \d+ characters across 3 lines\]/);
  assert.equal(stdout.buffer.includes("[out] second line"), false);
});

test("captureInputOnce preserves typed prefix when paste placeholder is shown", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(Buffer.from("Investigate: ", "utf8"));
  stdin.sendBytes(BRACKETED_PASTE_START);
  stdin.sendBytes(Buffer.from("[out] one\n[out] two", "utf8"));
  stdin.sendBytes(BRACKETED_PASTE_END);
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "Investigate: [out] one\n[out] two");
  assert.equal(
    stdout.buffer.includes("prompter> Investigate: [pasted 19 characters across 2 lines]"),
    true,
  );
});

test("captureInputOnce force-submits when paste end marker is missing", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 1000,
  });

  stdin.sendBytes(BRACKETED_PASTE_START);
  stdin.sendBytes(Buffer.from("[out] one\n[out] two", "utf8"));
  // No BRACKETED_PASTE_END here; simulate broken terminal marker.
  stdin.sendBytes(Buffer.from([0x0d])); // user presses Enter to submit

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "[out] one\n[out] two");
  assert.match(stdout.buffer, /\[pasted \d+ characters across 2 lines\]/);
});

test("captureInputOnce accepts ESC O M enter sequence for submit", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(Buffer.from("abc", "utf8"));
  stdin.sendBytes(Buffer.from([0x1b, 0x4f, 0x4d])); // ESC O M

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "abc");
});

test("captureInputOnce accepts split ESC O M enter sequence for submit", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(Buffer.from("abc", "utf8"));
  stdin.sendBytes(Buffer.from([0x1b]));
  stdin.sendBytes(Buffer.from([0x4f]));
  stdin.sendBytes(Buffer.from([0x4d]));

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "abc");
});

test("captureInputOnce accepts ESC O M submit after paste", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(BRACKETED_PASTE_START);
  stdin.sendBytes(Buffer.from("[out] one\n[out] two", "utf8"));
  // No explicit paste end marker; only ESC O M Enter sequence.
  stdin.sendBytes(Buffer.from([0x1b, 0x4f, 0x4d]));

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "[out] one\n[out] two");
});

test("captureInputOnce accepts split ESC O M submit after paste", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(BRACKETED_PASTE_START);
  stdin.sendBytes(Buffer.from("[out] one\n[out] two", "utf8"));
  stdin.sendBytes(Buffer.from([0x1b]));
  stdin.sendBytes(Buffer.from([0x4f]));
  stdin.sendBytes(Buffer.from([0x4d]));

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "[out] one\n[out] two");
});

test("captureInputOnce handles bracketed paste arriving in a single chunk with newlines", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  // Entire bracketed paste (start + content + end) arrives as one chunk.
  const content = Buffer.from("line1\nline2\nline3", "utf8");
  const single = Buffer.concat([BRACKETED_PASTE_START, content, BRACKETED_PASTE_END]);
  stdin.sendBytes(single);
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "line1\nline2\nline3");
  assert.match(stdout.buffer, /\[pasted 17 characters across 3 lines\]/);
  assert.equal(result.text.includes("[200~"), false);
  assert.equal(result.text.includes("[201~"), false);
});

test("captureInputOnce allows typing before and after paste then submitting", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  // Type a prefix
  stdin.sendBytes(Buffer.from("prefix: ", "utf8"));
  // Paste multi-line content in a single chunk
  const content = Buffer.from("pasted\nstuff", "utf8");
  stdin.sendBytes(Buffer.concat([BRACKETED_PASTE_START, content, BRACKETED_PASTE_END]));
  // Type a suffix
  stdin.sendBytes(Buffer.from(" suffix", "utf8"));
  // Submit
  stdin.sendBytes(Buffer.from([0x0d]));

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "prefix: pasted\nstuff suffix");
  assert.match(stdout.buffer, /prefix: \[pasted 12 characters across 2 lines\] suffix/);
});

test("captureInputOnce does not redraw during mid-paste chunks", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(BRACKETED_PASTE_START);
  const beforeMidPaste = stdout.buffer.length;

  // Simulate multiple mid-paste data chunks (like terminal sending 1KB at a time).
  stdin.sendBytes(Buffer.from("chunk1\nchunk2\n", "utf8"));
  stdin.sendBytes(Buffer.from("chunk3\nchunk4\n", "utf8"));
  stdin.sendBytes(Buffer.from("chunk5\nchunk6\n", "utf8"));
  const afterMidPaste = stdout.buffer.length;

  // No output should have been written during mid-paste chunks.
  assert.equal(afterMidPaste, beforeMidPaste, "should not redraw during active paste");

  // End paste and submit.
  stdin.sendBytes(BRACKETED_PASTE_END);
  stdin.sendBytes(Buffer.from([0x0d]));

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "chunk1\nchunk2\nchunk3\nchunk4\nchunk5\nchunk6\n");
  // Display should show the final paste summary once, after paste_end.
  assert.match(stdout.buffer, /\[pasted 42 characters across 7 lines\]/);
});

test("captureInputOnce clears input on Ctrl+U", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(Buffer.from("hello world", "utf8"));
  stdin.sendBytes(Buffer.from([0x15])); // Ctrl+U
  stdin.sendBytes(Buffer.from("new text", "utf8"));
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;
  assert.equal(result.type, "submit");
  assert.equal(result.text, "new text");
  assert.equal(stdout.buffer.includes("prompter> new text"), true);
});

test("captureInputOnce fails closed without TTY raw mode", async () => {
  const stdin = new EventEmitter();
  stdin.isTTY = false;
  const stdout = new FakeTTYOutput();

  await assert.rejects(
    captureInputOnce({ stdin, stdout }),
    (err) => err instanceof FailClosedError,
  );
});

test("captureInputOnce recognizes /settings command", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(Buffer.from("/settings", "utf8"));
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;
  assert.equal(result.type, "settings");
});

test("captureInputOnce recognizes /discover command", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  stdin.sendBytes(Buffer.from("/discover", "utf8"));
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;
  assert.equal(result.type, "discover");
});

test("captureInputOnce tab-completes unique slash command", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  // Type "/se" then Tab — should autocomplete to "/settings"
  stdin.sendBytes(Buffer.from("/se", "utf8"));
  stdin.sendBytes(Buffer.from([0x09])); // tab
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;
  assert.equal(result.type, "settings");
});

test("captureInputOnce shows command suggestions on slash", async () => {
  const stdin = new FakeTTYInput();
  const stdout = new FakeTTYOutput();

  const pending = captureInputOnce({
    stdin,
    stdout,
    pasteTimeoutMs: 200,
  });

  // Type "/" — should show all commands in output (with ANSI codes around them)
  stdin.sendBytes(Buffer.from("/", "utf8"));
  // Strip ANSI codes for assertion
  const plain = stdout.buffer.replace(/\u001b\[[0-9;]*m/g, "");
  assert.equal(plain.includes("/help"), true);
  assert.equal(plain.includes("/settings"), true);
  assert.equal(plain.includes("/quit"), true);

  // Finish by submitting a command
  stdin.sendBytes(Buffer.from("quit", "utf8"));
  stdin.sendBytes(Buffer.from([0x0d])); // enter

  const result = await pending;
  assert.equal(result.type, "quit");
});

