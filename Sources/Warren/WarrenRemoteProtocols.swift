import Foundation
import WarrenDesktop
import WarrenDomain

enum WarrenRemoteTabOrdering {
    static func moving(
        _ tabID: String,
        before destinationTabID: String?,
        in tabIDs: [String]
    ) -> [String] {
        guard let sourceIndex = tabIDs.firstIndex(of: tabID) else { return tabIDs }
        if let destinationTabID {
            guard destinationTabID != tabID, tabIDs.contains(destinationTabID) else {
                return tabIDs
            }
        }
        var result = tabIDs
        let moved = result.remove(at: sourceIndex)
        if let destinationTabID,
           let destinationIndex = result.firstIndex(of: destinationTabID) {
            result.insert(moved, at: destinationIndex)
        } else {
            result.append(moved)
        }
        return result
    }

    static func reconciling(
        preferredOrder: [String],
        availableTabIDs: [String]
    ) -> [String] {
        let available = Set(availableTabIDs)
        var seen: Set<String> = []
        let retained = preferredOrder.filter {
            available.contains($0) && seen.insert($0).inserted
        }
        return retained + availableTabIDs.filter { seen.insert($0).inserted }
    }
}

/// Parameters shared by the desktop terminal protocol and its tests.
enum WarrenRemoteTerminalProtocol {
    /// Parameters for a session output subscription. Passive subscribers do
    /// not claim focus; a selected cold attach opts into a control claim so
    /// the measured viewport is applied before the atomic checkpoint.
    static func subscribeParameters(
        sessionID: TerminalSessionID,
        size: TerminalSize?,
        anchor: TerminalOutputAnchor? = nil,
        claimControl: Bool = false
    ) -> [String: String] {
        var params = ["id": sessionID.description]
        if claimControl {
            params["claim"] = "true"
        }
        if let size {
            params["cols"] = String(size.columns)
            params["rows"] = String(size.rows)
        }
        if let anchor {
            params["epoch"] = String(anchor.epoch)
            params["sequence"] = String(anchor.sequence)
        }
        return params
    }

    /// Parameters for swapping the control lease without any output work.
    /// Tab promotion sends this instead of a replay-carrying attach so an
    /// ordinary switch performs zero recovery on the daemon.
    static func controlClaimParameters(sessionID: TerminalSessionID) -> [String: String] {
        ["id": sessionID.description, "output": "false"]
    }

    static func shouldAttach(
        previousTabID: String?,
        nextTabID: String?,
        mountedSurfaceCount: Int
    ) -> Bool {
        guard nextTabID != nil else { return false }
        return previousTabID != nextTabID || mountedSurfaceCount == 0
    }
}

enum WarrenRemoteTaskProtocol {
    private struct CreateResult: Decodable {
        let id: String
    }

    static func createRequest(
        _ creation: WarrenDesktopTaskCreationRequest
    ) -> (method: String, params: [String: String]) {
        var params = [
            "name": creation.name,
            "requestId": creation.requestID.uuidString.lowercased(),
        ]
        if let source = creation.source { params["source"] = source }
        if let externalID = creation.externalID { params["externalID"] = externalID }
        if let url = creation.url { params["url"] = url }
        return ("task.create", params)
    }

    static func taskID(from data: Data) throws -> TaskID {
        let result = try JSONDecoder().decode(CreateResult.self, from: data)
        guard let taskID = TaskID(uuidString: result.id) else {
            throw WarrenRemoteTaskProtocolError.invalidTaskID
        }
        return taskID
    }
}

private enum WarrenRemoteTaskProtocolError: LocalizedError {
    case invalidTaskID

    var errorDescription: String? {
        "The Host returned an invalid Task ID."
    }
}

enum WarrenRemoteWorkspaceProtocol {
    static func createParameters(
        projectID: ProjectID,
        taskID: TaskID?,
        creation: WorkspaceCreationRequest
    ) -> [String: String] {
        var params = [
            "project": projectID.description,
            "branch": creation.branch,
            "name": creation.displayName,
            "path": creation.path,
            "requestId": creation.requestID.uuidString.lowercased(),
            "runSetupScript": creation.runSetupScript ? "true" : "false",
        ]
        if let taskID {
            params["task"] = taskID.description
        }
        if !creation.setupArguments.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: creation.setupArguments),
           let value = String(data: data, encoding: .utf8) {
            params["setupArgs"] = value
        }
        return params
    }
}
