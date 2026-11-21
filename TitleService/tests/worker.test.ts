import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { handleRequest, type Env } from "../src/index";
import { FALLBACK_MODEL, PRIMARY_MODEL, type AIBinding } from "../src/ai";
import { normalizeTitle } from "../src/prompt";
import type { D1DatabaseLike, D1StatementLike, RateLimitBinding } from "../src/quota";

class InMemoryD1 implements D1DatabaseLike {
  readonly sqlite = new Database(":memory:");

  constructor() {
    this.sqlite.exec(`
      CREATE TABLE daily_quota (
        day TEXT NOT NULL,
        key TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, key)
      );
    `);
  }

  prepare(query: string): D1StatementLike {
    const sqlite = this.sqlite;
    const makeStatement = (bound: unknown[]): D1StatementLike => ({
      bind(...values: unknown[]) {
        return makeStatement(values);
      },
      async all<T = Record<string, unknown>>() {
        const stmt = sqlite.query(query);
        const results = stmt.all(...(bound as never[])) as T[];
        return { results };
      },
    });
    return makeStatement([]);
  }

  async batch<T = Record<string, unknown>>(
    statements: D1StatementLike[],
  ): Promise<Array<{ results: T[] }>> {
    const output: Array<{ results: T[] }> = [];
    for (const statement of statements) {
      output.push(await statement.all<T>());
    }
    return output;
  }
}

function makeEnv(overrides: Partial<Env> = {}): {
  env: Env;
  db: InMemoryD1;
  calls: Array<{ model: string; input: Record<string, unknown> }>;
} {
  const db = new InMemoryD1();
  const calls: Array<{ model: string; input: Record<string, unknown> }> = [];
  const ai: AIBinding = {
    async run(model, input) {
      calls.push({ model, input });
      return {
        choices: [{ message: { content: "Fix reconnect flow" } }],
      };
    },
  };
  const env: Env = {
    AI: ai,
    DB: db,
    QUOTA_SALT: "test-salt",
    ...overrides,
  };
  return { env, db, calls };
}

function postTitle(
  body: unknown,
  headers: Record<string, string> = {},
): Request {
  return new Request("https://title.warrenai.xyz/v1/title", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Device-Id": "device-12345678",
      "CF-Connecting-IP": "203.0.113.10",
      ...headers,
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

describe("normalizeTitle", () => {
  test("strips think tags, quotes, prefixes, and trailing punctuation", () => {
    expect(normalizeTitle("<think>let me consider</think>\nTitle: \"Fix reconnect flow.\"")).toBe(
      "Fix reconnect flow",
    );
    expect(normalizeTitle("标题：修复重连逻辑。")).toBe("修复重连逻辑");
    expect(normalizeTitle("<think>unclosed thinking")).toBe("");
  });
});

describe("TitleService HTTP contract", () => {
  test("health endpoint reports service metadata and limits", async () => {
    const { env } = makeEnv();
    const res = await handleRequest(new Request("https://title.warrenai.xyz/health"), env);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { ok: boolean; service: string; limits: { deviceDaily: number; ipDaily: number } };
    expect(data.ok).toBe(true);
    expect(data.service).toBe("warren-title");
    expect(data.limits.deviceDaily).toBe(50);
    expect(data.limits.ipDaily).toBe(300);
  });

  test("requires a valid X-Device-Id for public requests", async () => {
    const { env } = makeEnv();
    const res = await handleRequest(
      new Request("https://title.warrenai.xyz/v1/title", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user: "Fix reconnect" }),
      }),
      env,
    );
    expect(res.status).toBe(400);
  });

  test("generates title and returns remaining device quota without storing raw IDs", async () => {
    const { env, db, calls } = makeEnv();
    const res = await handleRequest(
      postTitle({
        mode: "initial",
        messages: [
          { role: "user", content: "# AGENTS.md scaffolding" },
          { role: "user", content: "Fix reconnect retry loop" },
          { role: "assistant", content: "I will inspect the backoff timer." },
        ],
      }),
      env,
    );
    expect(res.status).toBe(200);
    const payload = (await res.json()) as {
      title: string;
      quota: { limit: number; remaining: number; resetAt: string };
    };
    expect(payload.title).toBe("Fix reconnect flow");
    expect(payload.quota.limit).toBe(50);
    expect(payload.quota.remaining).toBe(49);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.model).toBe(PRIMARY_MODEL);

    const promptText = JSON.stringify(calls[0]?.input);
    expect(promptText).toContain("Fix reconnect retry loop");
    expect(promptText).not.toContain("# AGENTS.md scaffolding");

    // Verify raw device ID and IP never appear in D1 rows.
    const rows = db.sqlite.query("SELECT key, count FROM daily_quota").all() as Array<{
      key: string;
      count: number;
    }>;
    const keys = rows.map((r) => r.key).join(",");
    expect(keys).not.toContain("device-12345678");
    expect(keys).not.toContain("203.0.113.10");
  });

  test("enforces per-device daily limit", async () => {
    const { env } = makeEnv({ DEVICE_DAILY_LIMIT: "2" });

    const r1 = await handleRequest(postTitle({ user: "First request" }), env);
    expect(r1.status).toBe(200);
    const r2 = await handleRequest(postTitle({ user: "Second request" }), env);
    expect(r2.status).toBe(200);
    const r3 = await handleRequest(postTitle({ user: "Third request" }), env);
    expect(r3.status).toBe(429);
    const body = (await r3.json()) as { scope: string; quota: { remaining: number } };
    expect(body.scope).toBe("device");
    expect(body.quota.remaining).toBe(0);
    expect(r3.headers.get("Retry-After")).toBeTruthy();
  });

  test("enforces per-IP daily limit even when device IDs rotate", async () => {
    const { env } = makeEnv({ DEVICE_DAILY_LIMIT: "50", IP_DAILY_LIMIT: "2" });

    const r1 = await handleRequest(
      postTitle({ user: "First" }, { "X-Device-Id": "device-aaaaaaaa" }),
      env,
    );
    expect(r1.status).toBe(200);
    const r2 = await handleRequest(
      postTitle({ user: "Second" }, { "X-Device-Id": "device-bbbbbbbb" }),
      env,
    );
    expect(r2.status).toBe(200);
    const r3 = await handleRequest(
      postTitle({ user: "Third" }, { "X-Device-Id": "device-cccccccc" }),
      env,
    );
    expect(r3.status).toBe(429);
    const body = (await r3.json()) as { scope: string };
    expect(body.scope).toBe("ip");
  });

  test("enforces burst limiter before touching D1 or AI", async () => {
    const blocked: RateLimitBinding = {
      async limit() {
        return { success: false };
      },
    };
    const { env, calls } = makeEnv({ DEVICE_BURST: blocked });
    const res = await handleRequest(postTitle({ user: "Burst test" }), env);
    expect(res.status).toBe(429);
    expect(calls).toHaveLength(0);
  });

  test("owner bearer key bypasses public pool and device quota", async () => {
    const { env } = makeEnv({
      OWNER_KEY: "super-secret-owner-key",
      DEVICE_DAILY_LIMIT: "1",
      PUBLIC_POOL_DAILY_LIMIT: "1",
    });

    const pub = await handleRequest(postTitle({ user: "Public call" }), env);
    expect(pub.status).toBe(200);
    const blocked = await handleRequest(postTitle({ user: "Public blocked" }), env);
    expect(blocked.status).toBe(429);

    const ownerRes = await handleRequest(
      postTitle(
        { user: "Owner call" },
        { Authorization: "Bearer super-secret-owner-key", "X-Device-Id": "" },
      ),
      env,
    );
    expect(ownerRes.status).toBe(200);
  });

  test("falls back to secondary model when primary fails or emits empty output", async () => {
    const attempted: string[] = [];
    const { env } = makeEnv({
      AI: {
        async run(model) {
          attempted.push(model);
          if (model === PRIMARY_MODEL) {
            return { choices: [{ message: { content: "<think>only thinking</think>" } }] };
          }
          return { response: "调试数据库连接" };
        },
      },
    });
    const res = await handleRequest(postTitle({ user: "帮我调试数据库连接" }), env);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { title: string };
    expect(data.title).toBe("调试数据库连接");
    expect(attempted).toEqual([PRIMARY_MODEL, FALLBACK_MODEL]);
  });

  test("extracts text when Qwen3 places non-streaming output in reasoning_content", async () => {
    const { env } = makeEnv({
      AI: {
        async run() {
          return {
            choices: [{ message: { content: null, reasoning_content: "排查 Worker 限流逻辑" } }],
          };
        },
      },
    });
    const res = await handleRequest(postTitle({ user: "帮我排查一下限流逻辑" }), env);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { title: string };
    expect(data.title).toBe("排查 Worker 限流逻辑");
  });
});
