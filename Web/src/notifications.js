export const agentCompletionSoundStorageKey = "warren.agentCompletionSoundEnabled";
export const defaultAgentCompletionSoundEnabled = true;

// A short, gently ascending major triad keeps completion positive without
// sounding like an urgent alert. The final note lingers slightly longer to
// give the melody a natural resolution.
const agentCompletionMelody = [
  { frequency: 523.25, delay: 0, duration: 0.24, peak: 0.064 },
  { frequency: 659.25, delay: 0.1, duration: 0.3, peak: 0.058 },
  { frequency: 783.99, delay: 0.21, duration: 0.46, peak: 0.052 },
];

export function loadAgentCompletionSoundEnabled(storage) {
  try {
    const stored = (storage === undefined ? browserStorage() : storage)
      ?.getItem(agentCompletionSoundStorageKey);
    return stored === null || stored === undefined
      ? defaultAgentCompletionSoundEnabled
      : stored === "true";
  } catch {
    return defaultAgentCompletionSoundEnabled;
  }
}

export function saveAgentCompletionSoundEnabled(enabled, storage) {
  try {
    (storage === undefined ? browserStorage() : storage)
      ?.setItem(agentCompletionSoundStorageKey, String(Boolean(enabled)));
  } catch {
    // Storage can be unavailable in private or embedded browser contexts.
  }
}

function browserStorage() {
  try {
    return globalThis.localStorage;
  } catch {
    // Some embedded and private browser contexts throw when this getter runs.
    return null;
  }
}

// AgentTurnCompletionTracker converts the Host's latest-turn roster field
// into one local notification per successful completion. Its first snapshot
// is a baseline, not a historical notification source.
export class AgentTurnCompletionTracker {
  constructor() {
    this.initialized = false;
    this.turns = new Map();
  }

  reset() {
    this.initialized = false;
    this.turns.clear();
  }

  observe(sessions) {
    const nextTurns = new Map();
    for (const session of sessions) {
      const turn = normalizeTurn(session?.agentTurn);
      if (session?.id && turn) nextTurns.set(session.id, turn);
    }

    if (!this.initialized) {
      this.initialized = true;
      this.turns = nextTurns;
      return [];
    }

    const completed = [];
    for (const [sessionID, turn] of nextTurns) {
      const previous = this.turns.get(sessionID);
      if (isNewCompletion(turn, previous)) completed.push(sessionID);
    }
    this.turns = nextTurns;
    return completed;
  }
}

// AgentCompletionEventChannel keeps remote-state handling independent from
// presentation. Consumers can subscribe to completion events without
// coupling the roster tracker to a specific notification surface.
export class AgentCompletionEventChannel {
  constructor() {
    this.listeners = new Set();
  }

  subscribe(listener) {
    if (typeof listener !== "function") return () => {};
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit(event) {
    for (const listener of this.listeners) listener(event);
  }
}

// Browser audio requires a previous user gesture. App calls arm() for normal
// keyboard and pointer interaction so asynchronous completion events can play
// later without showing a permission prompt or bundling an audio asset.
export class AgentCompletionSound {
  constructor(AudioContextClass = globalThis.AudioContext || globalThis.webkitAudioContext) {
    this.AudioContextClass = AudioContextClass;
    this.context = null;
  }

  async arm() {
    const context = this.ensureContext();
    if (!context) return false;
    if (context.state === "suspended") {
      try {
        await context.resume();
      } catch {
        return false;
      }
    }
    return context.state === "running";
  }

  async play() {
    if (!await this.arm()) return false;
    const context = this.context;
    if (!context) return false;

    try {
      for (const note of agentCompletionMelody) {
        playTone(context, note.frequency, note.delay, note.duration, note.peak);
      }
      return true;
    } catch {
      return false;
    }
  }

  ensureContext() {
    if (this.context) return this.context;
    if (!this.AudioContextClass) return null;
    try {
      this.context = new this.AudioContextClass();
      return this.context;
    } catch {
      return null;
    }
  }
}

function normalizeTurn(value) {
  const id = Number(value?.id);
  const status = String(value?.status || "");
  return Number.isSafeInteger(id) && id > 0 && status ? { id, status } : null;
}

function isNewCompletion(turn, previous) {
  if (turn.status !== "completed") return false;
  if (!previous) return true;
  // Turn ids are monotonic for a transcript projection. A lower id means the
  // Host rebound or restarted; establish the new baseline without ringing for
  // an old completion.
  if (turn.id < previous.id) return false;
  return turn.id > previous.id || previous.status !== "completed";
}

function playTone(context, frequency, delay, duration, peak) {
  const start = context.currentTime + delay;
  const partials = [
    { ratio: 1, level: 1, type: "sine" },
    { ratio: 2, level: 0.16, type: "sine" },
  ];

  for (const partial of partials) {
    const oscillator = context.createOscillator();
    const gain = context.createGain();
    const partialFrequency = frequency * partial.ratio;
    oscillator.type = partial.type;
    oscillator.frequency.setValueAtTime(partialFrequency, start);
    gain.gain.setValueAtTime(0.0001, start);
    gain.gain.exponentialRampToValueAtTime(peak * partial.level, start + 0.018);
    gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);
    oscillator.connect(gain);
    gain.connect(context.destination);
    oscillator.start(start);
    oscillator.stop(start + duration + 0.02);
  }
}
