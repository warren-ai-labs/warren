import Foundation

struct WorkspaceCreationRequest: Hashable, Sendable {
    let requestID: UUID
    let displayName: String
    let branch: String
    let path: String
    let runSetupScript: Bool
    let setupArguments: [String]

    init(
        requestID: UUID = UUID(),
        displayName: String? = nil,
        branch: String,
        path: String = "",
        runSetupScript: Bool = false,
        setupArguments: [String] = []
    ) {
        self.requestID = requestID
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = normalizedName?.isEmpty == false ? normalizedName! : normalizedBranch
        self.branch = normalizedBranch
        self.path = path
        self.runSetupScript = runSetupScript
        self.setupArguments = setupArguments
    }
}
