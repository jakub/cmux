import CmuxSettings
import Foundation

extension TerminalController {
    /// Shared terminal-workspace creation entrypoint. Native mode retains the
    /// existing synchronous body; local-primary mode creates a tmux session and
    /// waits for its mirror so every caller receives authoritative workspace and
    /// surface ids instead of observing an optimistic native placeholder.
    @MainActor
    func v2WorkspaceCreateForCurrentMode(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil
    ) async -> V2CallResult {
        guard RemoteTmuxController.isLocalPrimaryEnabled else {
            return v2WorkspaceCreate(params: params, tabManager: resolvedTabManager)
        }
        guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
            return .err(
                code: "unavailable",
                message: String(
                    localized: "localTmux.primary.error.tabManagerUnavailable",
                    defaultValue: "TabManager not available"
                ),
                data: nil
            )
        }

        let unsupportedKeys = [
            "initial_command",
            "initial_env",
            "workspace_env",
            "layout",
            "group_id",
            "group_placement",
            "placement",
            "group_reference_workspace_id",
            "reference_workspace_id",
        ]
        if let unsupportedKey = unsupportedKeys.first(where: { v2HasNonNullParam(params, $0) }) {
            return .err(
                code: "unsupported_in_local_tmux",
                message: String.localizedStringWithFormat(
                    String(
                        localized: "localTmux.primary.error.unsupportedParameter",
                        defaultValue: "%@ is not supported while local tmux workspaces are enabled."
                    ),
                    unsupportedKey
                ),
                data: ["unsupported_param": unsupportedKey]
            )
        }

        let requestedWorkingDirectory = v2RawString(params, "working_directory")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory: String?
        if requestedWorkingDirectory?.isEmpty == false {
            workingDirectory = requestedWorkingDirectory
        } else if let raw = params["cwd"] {
            guard let value = raw as? String else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "localTmux.primary.error.invalidCwdType",
                        defaultValue: "cwd must be a string"
                    ),
                    data: nil
                )
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            workingDirectory = trimmed.isEmpty ? nil : trimmed
        } else {
            workingDirectory = nil
        }

        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = requestedTitle?.isEmpty == false ? requestedTitle : nil
        let description = v2RawString(params, "description")
        let shouldFocus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        guard let controller = AppDelegate.shared?.remoteTmuxController else {
            return .err(
                code: "unavailable",
                message: String(
                    localized: "localTmux.primary.error.controllerUnavailable",
                    defaultValue: "The local tmux controller is unavailable."
                ),
                data: nil
            )
        }
        do {
            let workspaceId = try await controller.createLocalPrimaryWorkspace(
                in: tabManager,
                title: title,
                workingDirectory: workingDirectory,
                select: shouldFocus
            )
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return .err(
                    code: "internal_error",
                    message: String(
                        localized: "localTmux.primary.error.mirrorResolution",
                        defaultValue: "cmux could not resolve the mirrored tmux workspace."
                    ),
                    data: nil
                )
            }
            workspace.setCustomDescription(description)
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            let surfaceId = workspace.focusedPanelId
            return .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "group_id": NSNull(),
                "group_ref": NSNull(),
                "surface_id": v2OrNull(surfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            ])
        } catch is CancellationError {
            return .err(
                code: "cancelled",
                message: String(
                    localized: "localTmux.primary.error.cancelled",
                    defaultValue: "Local tmux workspace creation was cancelled."
                ),
                data: nil
            )
        } catch {
            return .err(code: "local_tmux_error", message: error.localizedDescription, data: nil)
        }
    }

    // Shared workspace-create implementation: the workspace.create command moved
    // to ControlCommandCoordinator, but v2MobileWorkspaceCreate still drives
    // this body for the mobile data-plane create path.
    func v2WorkspaceCreate(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil
    ) -> V2CallResult {
        guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let requestedWorkingDirectory = v2RawString(params, "working_directory")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = (requestedWorkingDirectory?.isEmpty == false) ? requestedWorkingDirectory : nil

        let requestedInitialCommand = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil

        let rawInitialEnv = v2StringMap(params, "initial_env") ?? [:]
        let initialEnv = rawInitialEnv.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = pair.value
        }
        // Persistent per-workspace environment (issue #5995): applied to the
        // initial shell and every later pane/surface/split, then round-tripped
        // through session restore.
        let workspaceEnv = Workspace.sanitizedWorkspaceEnvironment(
            v2StringMap(params, "workspace_env") ?? [:]
        )
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let str = raw as? String else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            cwd = str
        } else {
            cwd = nil
        }

        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (requestedTitle?.isEmpty == false) ? requestedTitle : nil
        let description = v2RawString(params, "description")

        let groupId = v2UUID(params, "group_id")
        if v2HasNonNullParam(params, "group_id"), groupId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        let hasGroupPlacementParam = v2HasNonNullParam(params, "group_placement")
            || v2HasNonNullParam(params, "placement")
        let hasGroupReferenceParam = v2HasNonNullParam(params, "group_reference_workspace_id")
            || v2HasNonNullParam(params, "reference_workspace_id")
        if groupId == nil, hasGroupPlacementParam || hasGroupReferenceParam {
            return .err(
                code: "invalid_params",
                message: "group_id is required for group placement",
                data: nil
            )
        }
        let rawGroupPlacement = v2RawString(params, "group_placement")
            ?? (groupId == nil ? nil : v2RawString(params, "placement"))
        let groupPlacement = WorkspaceGroupNewPlacement(rawString: rawGroupPlacement)
        if let raw = rawGroupPlacement,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           groupPlacement == nil {
            return .err(code: "invalid_params", message: "Invalid group_placement", data: ["group_placement": raw])
        }
        let groupReferenceWorkspaceId: UUID?
        if v2HasNonNullParam(params, "group_reference_workspace_id") {
            guard let parsed = v2UUID(params, "group_reference_workspace_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid group_reference_workspace_id", data: nil)
            }
            groupReferenceWorkspaceId = parsed
        } else if v2HasNonNullParam(params, "reference_workspace_id") {
            guard let parsed = v2UUID(params, "reference_workspace_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid group_reference_workspace_id", data: nil)
            }
            groupReferenceWorkspaceId = parsed
        } else {
            groupReferenceWorkspaceId = nil
        }

        // Decode optional layout param (same JSON schema as cmux.json layout field).
        // Validate before creating the workspace so malformed layouts fail fast.
        var layoutNode: CmuxLayoutNode?
        if let rawLayout = params["layout"] {
            guard JSONSerialization.isValidJSONObject(rawLayout),
                  let layoutData = try? JSONSerialization.data(withJSONObject: rawLayout) else {
                return .err(code: "invalid_params", message: "layout must be a valid JSON object", data: nil)
            }
            do {
                layoutNode = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)
            } catch {
                return .err(code: "invalid_params", message: "Invalid layout: \(error.localizedDescription)", data: nil)
            }
        }

        var newId: UUID?
        var initialSurfaceId: UUID?
        let shouldFocus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
        let shouldEagerLoadTerminal = v2Bool(params, "eager_load_terminal") ?? !shouldFocus
        let shouldAutoRefreshMetadata = v2Bool(params, "auto_refresh_metadata") ?? true
        if let groupId {
            let validation = v2MainSync {
                let groupExists = tabManager.workspaceGroups.contains(where: { $0.id == groupId })
                let referenceIsMember = groupReferenceWorkspaceId.map { referenceWorkspaceId in
                    tabManager.tabs.contains { $0.id == referenceWorkspaceId && $0.groupId == groupId }
                } ?? true
                return (groupExists: groupExists, referenceIsMember: referenceIsMember)
            }
            guard validation.groupExists else {
                return .err(
                    code: "not_found",
                    message: "Group not found",
                    data: ["group_id": groupId.uuidString]
                )
            }
            guard validation.referenceIsMember else {
                return .err(
                    code: "invalid_params",
                    message: controlWorkspaceGroupStrings().invalidReferenceWorkspace,
                    data: ["group_reference_workspace_id": groupReferenceWorkspaceId?.uuidString ?? ""]
                )
            }
        }
        v2MainSync {
            let ws = tabManager.addWorkspace(
                title: title,
                workingDirectory: cwd,
                initialTerminalCommand: layoutNode == nil ? initialCommand : nil,
                initialTerminalEnvironment: layoutNode == nil ? initialEnv : [:],
                workspaceEnvironment: workspaceEnv,
                select: shouldFocus,
                eagerLoadTerminal: shouldEagerLoadTerminal,
                autoRefreshMetadata: shouldAutoRefreshMetadata
            )
            ws.setCustomDescription(description)
            if let layoutNode {
                ws.applyCustomLayout(layoutNode, baseCwd: cwd ?? ws.currentDirectory)
            }
            if let groupId {
                tabManager.addWorkspaceToGroup(
                    workspaceId: ws.id,
                    groupId: groupId,
                    placement: groupPlacement ?? .top,
                    referenceWorkspaceId: groupReferenceWorkspaceId
                )
            }
            newId = ws.id
            initialSurfaceId = ws.focusedPanelId
        }

        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
            "group_id": v2OrNull(groupId?.uuidString),
            "group_ref": v2Ref(kind: .workspaceGroup, uuid: groupId),
            "surface_id": v2OrNull(initialSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: initialSurfaceId)
        ])
    }

    func v2WorkspaceCloudVMOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let beforeIds = Set(tabManager.tabs.map(\.id))
        let didStart = AppDelegate.shared?.performCloudVMAction(
            tabManager: tabManager,
            debugSource: "rpc.workspace.cloud_vm_open"
        ) ?? false
        let createdWorkspace = tabManager.tabs.first { workspace in
            !beforeIds.contains(workspace.id)
                && workspace.panels.values.contains(where: { $0.panelType == .cloudVMLoading })
        }

        guard didStart || createdWorkspace != nil else {
            return .err(code: "unavailable", message: "Cloud VM action could not be started", data: nil)
        }

        let workspace = createdWorkspace ?? tabManager.selectedWorkspace
        let workspaceId = workspace?.id
        let surfaceId = workspace?.focusedPanelId
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "started": didStart,
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": v2OrNull(workspaceId?.uuidString),
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(surfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
        ])
    }

    func v2WorkspaceCloudVMTerminalReady(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawWorkspaceId = v2RawString(params, "workspace_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let workspaceId = UUID(uuidString: rawWorkspaceId) else {
            return .err(code: "invalid_params", message: "workspace_id is required", data: nil)
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }
        guard let command = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return .err(code: "invalid_params", message: "initial_command is required", data: ["workspace_id": workspaceId.uuidString])
        }

        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)
        guard let panel = workspace.replaceCloudVMLoadingSurfaceWithTerminal(
            workspaceId: workspaceId,
            initialCommand: command,
            focus: focus
        ) else {
            return .err(
                code: "not_found",
                message: "Cloud VM loading surface not found",
                data: ["workspace_id": workspaceId.uuidString]
            )
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": panel.id.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
        ])
    }

    func v2MobileWorkspaceCreate(params: [String: Any]) async -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        var createParams = params
        createParams["focus"] = false
        createParams["eager_load_terminal"] = false
        createParams["auto_refresh_metadata"] = false
        let createResult = await v2WorkspaceCreateForCurrentMode(
            params: createParams,
            tabManager: tabManager
        )
        switch createResult {
        case let .ok(payload):
            let createdWorkspaceID = (payload as? [String: Any])?["workspace_id"] as? String
            if let createdWorkspaceID {
                createParams["workspace_id"] = createdWorkspaceID
            }
            // workspace.updated emit is handled by MobileWorkspaceListObserver
            // which watches TabManager.tabsPublisher directly. Don't fire here.
            return v2MobileWorkspaceList(
                params: createParams,
                tabManager: tabManager,
                createdWorkspaceID: createdWorkspaceID
            )
        case .err:
            return createResult
        }
    }
}
