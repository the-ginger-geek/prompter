const START_SEQ = Buffer.from([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]); // ESC[200~
const END_SEQ = Buffer.from([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]); // ESC[201~
const SEQ_LEN = START_SEQ.length;

function matchesAt(buffer, index, seq) {
  if (index + seq.length > buffer.length) {
    return false;
  }
  for (let i = 0; i < seq.length; i += 1) {
    if (buffer[index + i] !== seq[i]) {
      return false;
    }
  }
  return true;
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

function couldBeSequencePrefix(candidate) {
  return isPrefix(candidate, START_SEQ) || isPrefix(candidate, END_SEQ);
}

export class BracketedPasteParser {
  constructor() {
    this.pending = Buffer.alloc(0);
    this.inPaste = false;
  }

  feed(chunk) {
    const input = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    const data = this.pending.length > 0 ? Buffer.concat([this.pending, input]) : input;
    const events = [];

    let index = 0;
    while (index < data.length) {
      if (matchesAt(data, index, START_SEQ)) {
        this.inPaste = true;
        events.push({ type: "paste_start" });
        index += SEQ_LEN;
        continue;
      }

      if (matchesAt(data, index, END_SEQ)) {
        this.inPaste = false;
        events.push({ type: "paste_end" });
        index += SEQ_LEN;
        continue;
      }

      const remaining = data.length - index;
      if (remaining < SEQ_LEN) {
        const tail = data.subarray(index);
        if (couldBeSequencePrefix(tail)) {
          break;
        }
      }

      events.push({
        type: "byte",
        byte: data[index],
        inPaste: this.inPaste,
      });
      index += 1;
    }

    this.pending = data.subarray(index);
    return events;
  }

  flushPendingAsBytes() {
    if (this.pending.length === 0) {
      return [];
    }

    const events = Array.from(this.pending, (byte) => ({
      type: "byte",
      byte,
      inPaste: this.inPaste,
    }));

    this.pending = Buffer.alloc(0);
    return events;
  }

  reset() {
    this.pending = Buffer.alloc(0);
    this.inPaste = false;
  }
}

export const BRACKETED_PASTE_START = START_SEQ;
export const BRACKETED_PASTE_END = END_SEQ;
