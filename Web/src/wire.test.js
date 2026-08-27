import test from "node:test";
import assert from "node:assert/strict";
import {
  binaryPayloadLimits,
  decodeAtomicStateFrame,
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
  assert.ok(encodeInput(inputPayload, { sessionID: "s" }));
  assert.equal(
    encodeInput(new Uint8Array(binaryPayloadLimits.input + 1), { sessionID: "s" }),
    null,
  );
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
