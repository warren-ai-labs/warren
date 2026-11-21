import type { ChatMessage } from "./prompt";
import { normalizeTitle } from "./prompt";

export const PRIMARY_MODEL = "@cf/qwen/qwen3-30b-a3b-fp8";
export const FALLBACK_MODEL = "@cf/meta/llama-3.1-8b-instruct-fp8-fast";

export interface AIBinding {
  run(model: string, input: Record<string, unknown>): Promise<unknown>;
}

export interface GeneratedTitle {
  title: string;
  model: string;
}

/**
 * Extracts raw text from Workers AI responses across both OpenAI-shaped and
 * legacy `{ response }` envelopes, including Qwen3's occasional fallback where
 * non-streaming output lands in `reasoning_content` while `content` is null.
 */
export function extractModelText(payload: unknown): string {
  if (!payload || typeof payload !== "object") return "";
  const record = payload as Record<string, unknown>;

  if (typeof record.response === "string" && record.response.trim()) {
    return record.response;
  }

  const choices = record.choices;
  if (Array.isArray(choices) && choices.length > 0) {
    const first = choices[0] as Record<string, unknown> | undefined;
    const message = first?.message as Record<string, unknown> | undefined;
    if (typeof message?.content === "string" && message.content.trim()) {
      return message.content;
    }
    if (typeof message?.reasoning_content === "string" && message.reasoning_content.trim()) {
      return message.reasoning_content;
    }
    if (typeof first?.text === "string" && first.text.trim()) {
      return first.text;
    }
  }

  return "";
}

async function runModel(
  ai: AIBinding,
  model: string,
  messages: ChatMessage[],
  disableThinking: boolean,
): Promise<string> {
  const input: Record<string, unknown> = {
    messages,
    max_tokens: 48,
    temperature: 0.2,
  };
  if (disableThinking) {
    input.chat_template_kwargs = { enable_thinking: false };
  }
  const raw = await ai.run(model, input);
  return normalizeTitle(extractModelText(raw));
}

export async function generateTitle(
  ai: AIBinding,
  messages: ChatMessage[],
  primaryModel = PRIMARY_MODEL,
  fallbackModel = FALLBACK_MODEL,
): Promise<GeneratedTitle> {
  let lastError: unknown = null;

  try {
    const title = await runModel(ai, primaryModel, messages, primaryModel.includes("qwen3"));
    if (title) {
      return { title, model: primaryModel };
    }
  } catch (error) {
    lastError = error;
  }

  if (fallbackModel && fallbackModel !== primaryModel) {
    try {
      const title = await runModel(ai, fallbackModel, messages, fallbackModel.includes("qwen3"));
      if (title) {
        return { title, model: fallbackModel };
      }
    } catch (error) {
      lastError = error;
    }
  }

  if (lastError instanceof Error) {
    throw lastError;
  }
  throw new Error("title model returned an empty response");
}
