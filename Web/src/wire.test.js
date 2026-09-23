import test from "node:test";
import assert from "node:assert/strict";
import {
  binaryPayloadLimits,
  decodeAtomicStateFrame,
  decodeBrowserFrame,
  decodeFrame,
  decodeOutputFrame,
  encodeInput,
  isBinaryEnvelope,
} from "./wire.js";

function envelope({ direction = 2, kind, header, payload }) {
  const headerBytes = new TextEncoder().encode(JSON.stringify(header));
  const frame = new Uint8Array(15 + headerBytes.length + payload.length);
  frame.set([0x44, 0x45, 0x4e, 0x42, 1, direction, kind], 0);
  const view = new DataView(frame.buffer);
  view.setUint32(7, headerBytes.length);
  view.setUint32(11, payload.length);
  frame.set(headerBytes, 15);
  frame.set(payload, 15 + headerBytes.length);
  return frame;
}

test("decodes a host output envelope", () => {
  const payload = new TextEncoder().encode("prompt\r\n");
  const header = {
    sessionID: "session-1",
    epoch: 3,
    sequence: 42,
    payloadLength: payload.length,
  };
  const headerBytes = new TextEncoder().encode(JSON.stringify(header));
  const frame = new Uint8Array(15 + headerBytes.length + payload.length);
  frame.set([0x44, 0x45, 0x4e, 0x42, 1, 2, 2], 0);
  const view = new DataView(frame.buffer);
  view.setUint32(7, headerBytes.length);
  view.setUint32(11, payload.length);
  frame.set(headerBytes, 15);
  frame.set(payload, 15 + headerBytes.length);

  assert.equal(isBinaryEnvelope(frame), true);
  const decoded = decodeOutputFrame(frame);
  assert.deepEqual(decoded.header, {
    sessionID: "session-1",
    epoch: 3,
    sequence: 42,
    payloadLength: payload.length,
  });
  assert.deepEqual([...decoded.payload], [...payload]);
});

test("rejects malformed and wrong-direction envelopes", () => {
  assert.equal(decodeOutputFrame(new Uint8Array(3)), null);
  const payload = new TextEncoder().encode("x");
  const headerBytes = new TextEncoder().encode(JSON.stringify({ sessionID: "s", epoch: 0, sequence: 0, payloadLength: 1 }));
  const frame = new Uint8Array(15 + headerBytes.length + 1);
  frame.set([0x44, 0x45, 0x4e, 0x42, 1, 1, 1], 0); // client-to-host input
  const view = new DataView(frame.buffer);
  view.setUint32(7, headerBytes.length);
  view.setUint32(11, payload.length);
  frame.set(headerBytes, 15);
  frame.set(payload, 15 + headerBytes.length);
  assert.equal(decodeOutputFrame(frame), null);
});

test("decodes an atomic terminal state envelope without treating it as output", () => {
  const payload = new TextEncoder().encode("\u001b[2J\u001b[Hprompt");
  const header = {
    sessionID: "session-1",
    epoch: 4,
    sequence: 128,
    format: "ghostline-vt-replay-v1",
    payloadLength: payload.length,
  };
  const headerBytes = new TextEncoder().encode(JSON.stringify(header));
  const frame = new Uint8Array(15 + headerBytes.length + payload.length);
  frame.set([0x44, 0x45, 0x4e, 0x42, 1, 2, 3], 0);
  const view = new DataView(frame.buffer);
  view.setUint32(7, headerBytes.length);
  view.setUint32(11, payload.length);
  frame.set(headerBytes, 15);
  frame.set(payload, 15 + headerBytes.length);

  const decoded = decodeAtomicStateFrame(frame);
  assert.equal(decoded.header.format, "ghostline-vt-replay-v1");
  assert.deepEqual([...decoded.payload], [...payload]);
  assert.deepEqual(decodeFrame(frame), { type: "atomicState", ...decoded });
  assert.equal(decodeOutputFrame(frame), null);
});

test("decodes a browser frame envelope without treating it as terminal output", () => {
  const payload = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
  const header = {
    sessionID: "browser-session-42",
    epoch: 2,
    sequence: 3001,
    format: "browser-frame-jpeg-v1",
    payloadLength: payload.length,
  };
  const frame = envelope({ kind: 4, header, payload });

  assert.equal(isBinaryEnvelope(frame), true);
  assert.equal(frame[6], 4, "kind is browserFrame");
  const decoded = decodeBrowserFrame(frame);
  assert.deepEqual(decoded.header, {
    sessionID: "browser-session-42",
    epoch: 2,
    sequence: 3001,
    format: "browser-frame-jpeg-v1",
    payloadLength: payload.length,
  });
  assert.deepEqual([...decoded.payload], [...payload]);

  // A browser frame is its own kind: the output decoder must refuse it, and
  // decodeFrame must not swallow it as an unknown kind either.
  assert.equal(decodeOutputFrame(frame), null);
  assert.deepEqual(decodeFrame(frame), { type: "browserFrame", ...decoded });
});

test("round-trips a browser frame sequence past the 32-bit boundary", () => {
  const payload = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
  const sequence = 4294967297; // 2^32 + 1: the wire sequence is 64-bit.
  const decoded = decodeBrowserFrame(envelope({
    kind: 4,
    header: {
      sessionID: "browser-session-64bit",
      epoch: 9,
      sequence,
      format: "browser-frame-jpeg-v1",
      payloadLength: payload.length,
    },
    payload,
  }));
  assert.equal(decoded.header.sessionID, "browser-session-64bit");
  assert.equal(decoded.header.sequence, sequence);
});

test("returns a browser frame payload as raw bytes rather than decoded text", () => {
  // A JPEG body is arbitrary bytes: 0xff, 0xfe and lone 0x80 are not valid
  // UTF-8, so a lossy text decode would rewrite them as U+FFFD.
  const payload = new Uint8Array([
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46,
    0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xff, 0xfe, 0x80, 0xc0, 0xed, 0xa0, 0x80, 0xf4, 0x90, 0x80, 0x80,
  ]);
  assert.throws(() => new TextDecoder("utf-8", { fatal: true }).decode(payload));
  assert.ok(new TextDecoder().decode(payload).includes("�"), "fixture is not valid UTF-8");

  const decoded = decodeBrowserFrame(envelope({
    kind: 4,
    header: {
      sessionID: "browser-session-7",
      epoch: 0,
      sequence: 5,
      format: "browser-frame-jpeg-v1",
      payloadLength: payload.length,
    },
    payload,
  }));
  assert.ok(decoded.payload instanceof Uint8Array, "payload stays binary");
  assert.equal(decoded.payload.length, payload.length);
  assert.deepEqual([...decoded.payload], [...payload]);
  assert.equal(decoded.payload[0], 0xff);
  assert.equal(decoded.payload[20], 0xff);
  assert.equal(decoded.payload[22], 0x80);
});

test("encodes client input envelopes", () => {
  const payload = new TextEncoder().encode("ls\r");
  const encoded = encodeInput(payload, { sessionID: "s-1", attachmentID: "a-1", sequence: 9 });
  assert.equal(isBinaryEnvelope(encoded), true);
  assert.equal(encoded[5], 1, "direction is client-to-host");
  assert.equal(encoded[6], 1, "kind is input");
});

test("enforces distinct output and atomic-state payload limits", () => {
  const outputPayload = new Uint8Array(binaryPayloadLimits.output);
  const outputFrame = envelope({
    kind: 2,
    header: { sessionID: "s", epoch: 1, sequence: 0, payloadLength: outputPayload.length },
    payload: outputPayload,
  });
  assert.ok(decodeOutputFrame(outputFrame));

  const oversizedOutput = envelope({
    kind: 2,
    header: { sessionID: "s", epoch: 1, sequence: 0, payloadLength: binaryPayloadLimits.output + 1 },
    payload: new Uint8Array(binaryPayloadLimits.output + 1),
  });
  assert.equal(decodeOutputFrame(oversizedOutput), null);

  const atomicPayload = new Uint8Array(binaryPayloadLimits.atomicState);
  const atomicFrame = envelope({
    kind: 3,
    header: {
      sessionID: "s",
      epoch: 1,
      sequence: 0,
      format: "ghostline-vt-replay-v1",
      payloadLength: atomicPayload.length,
    },
    payload: atomicPayload,
  });
  assert.ok(decodeAtomicStateFrame(atomicFrame));

  const oversizedAtomic = envelope({
    kind: 3,
    header: {
      sessionID: "s",
      epoch: 1,
      sequence: 0,
      format: "ghostline-vt-replay-v1",
      payloadLength: binaryPayloadLimits.atomicState + 1,
    },
    payload: new Uint8Array(binaryPayloadLimits.atomicState + 1),
  });
  assert.equal(decodeAtomicStateFrame(oversizedAtomic), null);

  const inputPayload = new Uint8Array(binaryPayloadLimits.input);
  assert.ok(encodeInput(inputPayload, { sessionID: "s", attachmentID: "a" }));
  assert.equal(
    encodeInput(new Uint8Array(binaryPayloadLimits.input + 1), { sessionID: "s", attachmentID: "a" }),
    null,
  );
});

test("enforces the browser frame payload limit", () => {
  const atLimit = new Uint8Array(binaryPayloadLimits.browserFrame);
  const frame = envelope({
    kind: 4,
    header: {
      sessionID: "s",
      epoch: 1,
      sequence: 0,
      format: "browser-frame-jpeg-v1",
      payloadLength: atLimit.length,
    },
    payload: atLimit,
  });
  assert.ok(decodeBrowserFrame(frame));
  assert.ok(decodeFrame(frame));

  const oversized = new Uint8Array(binaryPayloadLimits.browserFrame + 1);
  const oversizedFrame = envelope({
    kind: 4,
    header: {
      sessionID: "s",
      epoch: 1,
      sequence: 0,
      format: "browser-frame-jpeg-v1",
      payloadLength: oversized.length,
    },
    payload: oversized,
  });
  assert.equal(decodeBrowserFrame(oversizedFrame), null);
  assert.equal(decodeFrame(oversizedFrame), null);
});

test("rejects atomic frames with bad direction, format, or payload length", () => {
  const payload = new Uint8Array([1, 2]);
  const valid = envelope({
    kind: 3,
    header: { sessionID: "s", epoch: 2, sequence: 4, format: "ghostline-vt-replay-v1", payloadLength: payload.length },
    payload,
  });
  valid[5] = 1;
  assert.equal(decodeAtomicStateFrame(valid), null);

  const missingFormat = envelope({
    kind: 3,
    header: { sessionID: "s", epoch: 2, sequence: 4, format: "", payloadLength: payload.length },
    payload,
  });
  assert.equal(decodeAtomicStateFrame(missingFormat), null);

  const mismatchedHeader = envelope({
    kind: 3,
    header: { sessionID: "s", epoch: 2, sequence: 4, format: "ghostline-vt-replay-v1", payloadLength: payload.length + 1 },
    payload,
  });
  assert.equal(decodeAtomicStateFrame(mismatchedHeader), null);
});

test("rejects browser frames with bad direction, format, or payload length", () => {
  const payload = new Uint8Array([1, 2]);
  const valid = envelope({
    kind: 4,
    header: { sessionID: "s", epoch: 2, sequence: 4, format: "browser-frame-jpeg-v1", payloadLength: payload.length },
    payload,
  });
  valid[5] = 1;
  assert.equal(decodeBrowserFrame(valid), null);
  assert.equal(decodeFrame(valid), null);

  for (const format of ["", "browser-frame-png-v1", "browser-frame-jpeg-v2", "ghostline-vt-replay-v1"]) {
    const unsupported = envelope({
      kind: 4,
      header: { sessionID: "s", epoch: 2, sequence: 4, format, payloadLength: payload.length },
      payload,
    });
    assert.equal(decodeBrowserFrame(unsupported), null, `format ${JSON.stringify(format)} must be rejected`);
    assert.equal(decodeFrame(unsupported), null, `format ${JSON.stringify(format)} must not be dispatched`);
  }

  const missingFormat = envelope({
    kind: 4,
    header: { sessionID: "s", epoch: 2, sequence: 4, payloadLength: payload.length },
    payload,
  });
  assert.equal(decodeBrowserFrame(missingFormat), null);

  const mismatchedHeader = envelope({
    kind: 4,
    header: { sessionID: "s", epoch: 2, sequence: 4, format: "browser-frame-jpeg-v1", payloadLength: payload.length + 1 },
    payload,
  });
  assert.equal(decodeBrowserFrame(mismatchedHeader), null);
});

test("rejects truncated and corrupt browser frames instead of throwing", () => {
  const payload = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
  const header = {
    sessionID: "s",
    epoch: 1,
    sequence: 2,
    format: "browser-frame-jpeg-v1",
    payloadLength: payload.length,
  };
  const frame = envelope({ kind: 4, header, payload });
  const headerLength = frame.length - 15 - payload.length;

  const badMagic = frame.slice();
  badMagic[0] = 0x00;
  assert.equal(decodeBrowserFrame(badMagic), null);
  assert.equal(decodeFrame(badMagic), null);

  assert.equal(decodeBrowserFrame(frame.subarray(0, 14)), null); // prefix alone
  assert.equal(decodeBrowserFrame(frame.subarray(0, frame.length - 1)), null); // payload cut short
  assert.equal(decodeBrowserFrame(frame.subarray(0, 15)), null); // header missing

  const headerPastEnd = frame.slice();
  new DataView(headerPastEnd.buffer).setUint32(7, headerLength + 64);
  assert.equal(decodeBrowserFrame(headerPastEnd), null);
  assert.equal(decodeFrame(headerPastEnd), null);

  const headerTooLarge = frame.slice();
  new DataView(headerTooLarge.buffer).setUint32(7, 16 * 1024 + 1);
  assert.equal(decodeBrowserFrame(headerTooLarge), null);

  const payloadPastEnd = frame.slice();
  new DataView(payloadPastEnd.buffer).setUint32(11, payload.length + 64);
  assert.equal(decodeBrowserFrame(payloadPastEnd), null);
  assert.equal(decodeFrame(payloadPastEnd), null);

  const garbageHeader = frame.slice();
  garbageHeader.set([0xff, 0xfe, 0x00, 0x01], 15); // not JSON
  assert.equal(decodeBrowserFrame(garbageHeader), null);
  assert.equal(decodeFrame(garbageHeader), null);
});
