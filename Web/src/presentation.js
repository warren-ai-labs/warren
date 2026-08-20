export const presentationLayers = {
  content: 0,
  inline: 1,
  inlineOverlay: 10,
  drawer: 20,
  popover: 30,
  command: 40,
  modal: 50,
  menu: 60,
};

export function topRole(stack) {
  return stack.length ? stack[stack.length - 1] : null;
}

export function pushRole(stack, role) {
  return [...stack, role];
}

export function popRole(stack) {
  return stack.slice(0, -1);
}

export function shouldDismissOnBackdrop(role, hasEdits = false) {
  if (role === "modal") return false;
  if (role === "sheet") return !hasEdits;
  return true;
}

export function shouldDismissOnEscape(role) {
  return ["modal", "sheet", "commandSurface", "popover", "menu"].includes(role);
}

export function presentationLayer(role) {
  switch (role) {
    case "modal":
    case "sheet":
      return presentationLayers.modal;
    case "commandSurface":
      return presentationLayers.command;
    case "menu":
      return presentationLayers.menu;
    case "popover":
      return presentationLayers.popover;
    case "status":
      return presentationLayers.inlineOverlay;
    default:
      return presentationLayers.content;
  }
}
