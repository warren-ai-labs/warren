// OSC 7501 program status, folded into the one activity encoding.
//
// The Program Status Protocol lets any program tell the terminal what it is
// doing. Its states resolve to the same marks `activity.js` defines for an
// Agent, so a row says what it asks of a person the same way whatever reported
// it. Only the label differs, because nothing bound the program to an Agent.

const PROGRAM_MARK_LABEL = {
  approvalNeeded: "Program needs approval",
  inputNeeded: "Program needs input",
  attentionUnspecified: "Program needs attention",
  failed: "Program failed",
  working: "Program working",
  ready: "Program finished",
};

/// The activity mark for a program status, or `null` when a row should draw
/// nothing.
///
/// `idle` draws nothing: it is the resting state of every shell. `done` draws
/// the finished mark and keeps it until a new report replaces it, so a finished
/// build can be found later; a program report carries no record of having been
/// read, so it is not acknowledged away. `auth`, an unknown kind, and no kind
/// all read as a request Warren cannot name, and an unknown state never
/// degrades into a known one.
export function resolveProgramStatusMark(programStatus) {
  if (!programStatus) return null;
  switch (String(programStatus.state || "").toLowerCase()) {
    case "working":
      return "working";
    case "error":
      return "failed";
    case "done":
      return "ready";
    case "blocked":
      switch (String(programStatus.kind || "").toLowerCase()) {
        case "permission": return "approvalNeeded";
        case "question": return "inputNeeded";
        default: return "attentionUnspecified";
      }
    default:
      return null;
  }
}

/// The label assistive technology receives for a program's mark.
export function programStatusMarkLabel(mark) {
  return mark ? PROGRAM_MARK_LABEL[mark] || null : null;
}

/// The tooltip: the program's own message when it sent one, otherwise the
/// label.
export function programStatusDetail(programStatus, mark) {
  if (!mark) return "";
  const message = typeof programStatus?.message === "string" ? programStatus.message.trim() : "";
  return message || programStatusMarkLabel(mark);
}
