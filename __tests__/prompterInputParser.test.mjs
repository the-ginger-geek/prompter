import test from "node:test";
import assert from "node:assert/strict";

import {
  BRACKETED_PASTE_END,
  BRACKETED_PASTE_START,
  BracketedPasteParser,
} from "../prompterInputParser.mjs";

test("parser handles bracketed paste split across chunks", () => {
  const parser = new BracketedPasteParser();

  const first = parser.feed(Buffer.from("\u001b[20", "utf8"));
  assert.equal(first.length, 0);

  const second = parser.feed(Buffer.from("0~abc", "utf8"));
  assert.equal(second[0].type, "paste_start");
  assert.deepEqual(
    second.slice(1).map((event) => String.fromCharCode(event.byte)),
    ["a", "b", "c"],
  );
  assert.equal(parser.inPaste, true);

  const third = parser.feed(Buffer.from(BRACKETED_PASTE_END));
  assert.deepEqual(third, [{ type: "paste_end" }]);
  assert.equal(parser.inPaste, false);
});

test("parser does not swallow malformed escape sequences", () => {
  const parser = new BracketedPasteParser();
  const events = parser.feed(Buffer.from("\u001b[20X", "utf8"));

  const bytes = events.map((event) => event.byte);
  assert.equal(bytes.length, 5);
  assert.deepEqual(bytes, [0x1b, 0x5b, 0x32, 0x30, 0x58]);
});

test("flushPendingAsBytes flushes partial prefixes", () => {
  const parser = new BracketedPasteParser();
  parser.feed(Buffer.from(BRACKETED_PASTE_START.subarray(0, 3)));
  const pending = parser.flushPendingAsBytes();

  assert.equal(pending.length, 3);
  assert.deepEqual(
    pending.map((event) => event.byte),
    Array.from(BRACKETED_PASTE_START.subarray(0, 3)),
  );
});
