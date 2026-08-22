import { open } from "@raycast/api";

export const WARREN_URL_SCHEME = "warren://terminal?group=";
export const DEFAULT_GROUP = "Inbox";
export const DEFAULT_APPLICATION = "Warren";

export interface OpenTerminalGroupOptions {
  application?: string;
  group?: string;
}

function cleanSelector(value: string | undefined, fallback: string): string {
  const selector = value?.trim();
  return selector || fallback;
}

export function terminalGroupURL(group: string): string {
  return `${WARREN_URL_SCHEME}${encodeURIComponent(group)}`;
}

export async function openTerminalGroup(
  options: OpenTerminalGroupOptions = {},
): Promise<string> {
  const group = cleanSelector(options.group, DEFAULT_GROUP);
  const application = cleanSelector(options.application, DEFAULT_APPLICATION);

  await open(terminalGroupURL(group), application);
  return group;
}
