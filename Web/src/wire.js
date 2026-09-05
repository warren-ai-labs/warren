const MAGIC = [0x44, 0x45, 0x4e, 0x42]; // "DENB"
const VERSION = 1;
const DIRECTION_CLIENT_TO_HOST = 1;
const DIRECTION_HOST_TO_CLIENT = 2;
const KIND_INPUT = 1;
const KIND_OUTPUT = 2;
const KIND_ATOMIC_STATE = 3;
const MAX_HEADER = 16 * 1024;
const MAX_PAYLOAD = 8 * 1024 * 1024;
const MAX_ATOMIC_STATE_PAYLOAD = 64 * 1024 * 1024;
const PREFIX_LENGTH = 15;

export const binaryPayloadLimits = Object.freeze({
  output: MAX_PAYLOAD,
  input: MAX_PAYLOAD,
  atomicState: MAX_ATOMIC_STATE_PAYLOAD,
});

export function isBinaryEnvelope(bytes) {
  if (!bytes || bytes.length < PREFIX_LENGTH) return false;
  for (let index = 0; index < MAGIC.length; index += 1) {
    if (bytes[index] !== MAGIC[index]) return false;
  }
  return bytes[4] === VERSION;
}

function decodeEnvelope(bytes, expectedKind = null) {
  if (!isBinaryEnvelope(bytes)) return null;
  const direction = bytes[5];
  const kind = bytes[6];
  if (direction !== DIRECTION_HOST_TO_CLIENT
    || (expectedKind !== null && kind !== expectedKind)) return null;

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const headerLength = view.getUint32(7);
  const payloadLength = view.getUint32(11);
  const payloadLimit = kind === KIND_ATOMIC_STATE
    ? MAX_ATOMIC_STATE_PAYLOAD
    : MAX_PAYLOAD;
  if (headerLength > MAX_HEADER || payloadLength > payloadLimit) return null;
  const headerEnd = PREFIX_LENGTH + headerLength;
  const expected = headerEnd + payloadLength;
  if (bytes.length !== expected) return null;

  let header;
  try {
    header = JSON.parse(new TextDecoder().decode(bytes.subarray(PREFIX_LENGTH, headerEnd)));
  } catch {
    return null;
  }
  if (!header || header.payloadLength !== payloadLength) return null;
  return { kind, header, payload: bytes.slice(headerEnd, expected) };
}

export function decodeOutputFrame(bytes) {
  const decoded = decodeEnvelope(bytes, KIND_OUTPUT);
  if (!decoded) return null;
  return {
    header: {
      sessionID: decoded.header.sessionID,
      epoch: decoded.header.epoch,
      sequence: decoded.header.sequence,
      payloadLength: decoded.header.payloadLength,
    },
    payload: decoded.payload,
  };
}

export function decodeAtomicStateFrame(bytes) {
  const decoded = decodeEnvelope(bytes, KIND_ATOMIC_STATE);
  if (!decoded || typeof decoded.header.format !== "string" || !decoded.header.format) return null;
  return {
    header: {
      sessionID: decoded.header.sessionID,
      epoch: decoded.header.epoch,
      sequence: decoded.header.sequence,
      format: decoded.header.format,
      payloadLength: decoded.header.payloadLength,
    },
    payload: decoded.payload,
  };
}

export function decodeFrame(bytes) {
  if (!isBinaryEnvelope(bytes)) return null;
  if (bytes[6] === KIND_OUTPUT) {
    const output = decodeOutputFrame(bytes);
    return output ? { type: "output", ...output } : null;
  }
  if (bytes[6] === KIND_ATOMIC_STATE) {
    const state = decodeAtomicStateFrame(bytes);
    return state ? { type: "atomicState", ...state } : null;
  }
  return null;
}

export function encodeInput(payload, { sessionID = "", attachmentID = "", sequence = 0, version = "3.0" } = {}) {
  const header = {
    version,
    sessionID,
    attachmentID,
    payloadLength: payload.length,
    sequence,
  };
  const headerBytes = new TextEncoder().encode(JSON.stringify(header));
  if (headerBytes.length > MAX_HEADER || payload.length > MAX_PAYLOAD) return null;

  const result = new Uint8Array(PREFIX_LENGTH + headerBytes.length + payload.length);
  result.set(MAGIC, 0);
  result[4] = VERSION;
  result[5] = DIRECTION_CLIENT_TO_HOST;
  result[6] = KIND_INPUT;
  const view = new DataView(result.buffer);
  view.setUint32(7, headerBytes.length);
  view.setUint32(11, payload.length);
  result.set(headerBytes, PREFIX_LENGTH);
  result.set(payload, PREFIX_LENGTH + headerBytes.length);
  return result;
}
