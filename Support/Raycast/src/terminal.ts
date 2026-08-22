import { getPreferenceValues, showHUD, showToast, Toast } from "@raycast/api";
import { openTerminalGroup } from "./lib/warren";

interface Preferences {
  application?: string;
  group?: string;
}

export default async function Command() {
  const preferences = getPreferenceValues<Preferences>();

  try {
    const group = await openTerminalGroup(preferences);
    await showHUD(`Opened Warren · ${group}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await showToast({
      style: Toast.Style.Failure,
      title: "Unable to open Warren",
      message,
    });
  }
}
