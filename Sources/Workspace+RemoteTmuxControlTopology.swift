import Bonsplit
import CmuxWorkspaces
import Foundation

@MainActor
extension Workspace {
    typealias ControlSurfaceProjection = (
        surfaceID: UUID,
        paneID: UUID?,
        panel: any Panel
    )
    enum RemoteTmuxControlSurfaceTarget {
        case notRemote
        case unresolvedMirror
        case pane(RemoteTmuxControlPaneLocation)
    }

    func remoteTmuxControlPane(paneID: UUID) -> RemoteTmuxControlPaneLocation? {
        if let sessionMirror = remoteTmuxSessionMirror {
            return sessionMirror.controlPaneLocation(paneID: paneID)
        }
        for (containerPanelID, mirror) in remoteTmuxWindowMirrors {
            if let pane = mirror.controlPane(paneID: paneID) {
                return RemoteTmuxControlPaneLocation(
                    containerPanelID: containerPanelID,
                    owner: mirror,
                    windowMirror: mirror,
                    pane: pane
                )
            }
        }
        return nil
    }

    func remoteTmuxControlPane(surfaceID: UUID) -> RemoteTmuxControlPaneLocation? {
        if let sessionMirror = remoteTmuxSessionMirror {
            return sessionMirror.controlPaneLocation(surfaceID: surfaceID)
        }
        for (containerPanelID, mirror) in remoteTmuxWindowMirrors {
            if let pane = mirror.controlPane(surfaceID: surfaceID) {
                return RemoteTmuxControlPaneLocation(
                    containerPanelID: containerPanelID,
                    owner: mirror,
                    windowMirror: mirror,
                    pane: pane
                )
            }
        }
        return nil
    }

    func remoteTmuxControlPanes(
        containerPanelID: UUID
    ) -> [RemoteTmuxControlPaneLocation] {
        if let sessionMirror = remoteTmuxSessionMirror {
            return sessionMirror.controlPaneLocations(containerPanelID: containerPanelID)
        }
        guard let mirror = remoteTmuxWindowMirrors[containerPanelID] else { return [] }
        return mirror.controlPanes().map {
            RemoteTmuxControlPaneLocation(
                containerPanelID: containerPanelID,
                owner: mirror,
                windowMirror: mirror,
                pane: $0
            )
        }
    }

    func isRemoteTmuxControlContainer(_ panelID: UUID) -> Bool {
        remoteTmuxSessionMirror?.windowId(forPanel: panelID) != nil
            || remoteTmuxWindowMirrors[panelID] != nil
    }

    func activeRemoteTmuxControlPane(
        containerPanelID: UUID
    ) -> RemoteTmuxControlPaneLocation? {
        let locations = remoteTmuxControlPanes(containerPanelID: containerPanelID)
        return locations.first(where: { $0.pane.isFocused }) ?? locations.first
    }

    /// Resolves every mirror-owned surface identity without conflating an
    /// unresolved mirror with an ordinary workspace surface.
    func remoteTmuxControlSurfaceTarget(surfaceID: UUID) -> RemoteTmuxControlSurfaceTarget {
        if let location = remoteTmuxControlPane(surfaceID: surfaceID) {
            return .pane(location)
        }
        guard isRemoteTmuxControlContainer(surfaceID) else {
            return .notRemote
        }
        // The wrapper UUID identifies the mirror container, not a tmux pane.
        // Never alias it to the mutable active pane: callers may cache handles,
        // and a later focus publication would silently retarget that handle.
        return .unresolvedMirror
    }

    /// Intercepts focus requests the remote tmux layer owns. Focus activation
    /// is dropped while mirror mutations suppress it, and a mirror-projected
    /// pane surface — which is not a Bonsplit tab, so the ordinary focus path
    /// cannot resolve it — routes through the pane's sole mutation owner
    /// (select-pane on the remote) before focusing the mirror's container
    /// panel, mirroring `focusRemoteTmuxControlPane`. A single-pane session
    /// window projects its display panel as both container and surface; that
    /// identity stays on the ordinary focus path, both to terminate the
    /// container recursion and because the container is a real Bonsplit tab
    /// the ordinary path already handles. Returns true when the request was
    /// consumed.
    func remoteTmuxMirrorInterceptsFocusPanel(
        _ panelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        trigger: FocusPanelTrigger,
        focusIntent: PanelFocusIntent?
    ) -> Bool {
        if remoteTmuxMirrorMutations.suppressesFocusActivation { return true }
        if remoteTmuxFocusInterceptorBypassPanelID == panelId { return false }
        guard let location = remoteTmuxControlPane(surfaceID: panelId) else { return false }
        // A window's original single pane can retain the outer container UUID
        // after tmux splits it. It is then both a real outer Bonsplit tab and a
        // projected inner pane: select it remotely here, then let the ordinary
        // path below activate that same outer tab using the updated projection.
        if location.containerPanelID == panelId {
            guard location.windowMirror != nil else { return false }
            if !location.pane.isFocused {
                guard location.controlFocus() else { return true }
                location.windowMirror?.setActivePane(location.pane.tmuxPaneID, fromTmux: true)
            }
            return false
        }
        if !location.pane.isFocused {
            guard location.controlFocus() else { return true }
            // The control stream remains authoritative, but its publication is
            // asynchronous. Project the accepted selection immediately so the
            // UI and AppKit first responder cannot snap back to the old pane.
            location.windowMirror?.setActivePane(location.pane.tmuxPaneID, fromTmux: true)
        }
        let previousBypassPanelID = remoteTmuxFocusInterceptorBypassPanelID
        remoteTmuxFocusInterceptorBypassPanelID = location.containerPanelID
        defer { remoteTmuxFocusInterceptorBypassPanelID = previousBypassPanelID }
        focusPanel(
            location.containerPanelID,
            previousHostedView: previousHostedView,
            trigger: trigger,
            focusIntent: focusIntent
        )
        return true
    }

    /// Canonicalizes an explicit control-plane terminal target. Hidden mirror
    /// containers fail closed instead of exposing their stale wrapper panel.
    func controlSurfaceTarget(for surfaceID: UUID) -> ControlSurfaceProjection? {
        switch remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            return (location.pane.panel.id, location.pane.paneID.id, location.pane.panel)
        case .unresolvedMirror:
            return nil
        case .notRemote:
            guard let panel = panels[surfaceID] else { return nil }
            return (surfaceID, paneId(forPanelId: surfaceID)?.id, panel)
        }
    }

    func controlTerminalTarget(for surfaceID: UUID) -> (surfaceID: UUID, panel: TerminalPanel)? {
        guard let target = controlSurfaceTarget(for: surfaceID),
              let panel = target.panel as? TerminalPanel else { return nil }
        return (target.surfaceID, panel)
    }

    func controlTerminalPanel(for surfaceID: UUID) -> TerminalPanel? {
        controlTerminalTarget(for: surfaceID)?.panel
    }

    /// Projects a workspace-owned panel into the identity exposed by the
    /// control plane. A mirror container resolves only when tmux has published
    /// an authoritative active pane; ordinary panels keep their Bonsplit pane.
    func controlSurfaceProjection(
        forContainerPanelID containerPanelID: UUID
    ) -> ControlSurfaceProjection? {
        if isRemoteTmuxControlContainer(containerPanelID) {
            guard let active = activeRemoteTmuxControlPane(containerPanelID: containerPanelID) else {
                return nil
            }
            return (active.pane.panel.id, active.pane.paneID.id, active.pane.panel)
        }
        guard let panel = panels[containerPanelID] else { return nil }
        return (containerPanelID, paneId(forPanelId: containerPanelID)?.id, panel)
    }

    /// Whether a terminal surface is the effective focus target right now.
    /// Outer Bonsplit owns selection for a mirrored tmux window; the mirror's
    /// active pane owns the terminal surface nested inside that selection.
    func matchesCurrentTerminalFocusTarget(surfaceID: UUID) -> Bool {
        if let location = remoteTmuxControlPane(surfaceID: surfaceID) {
            guard focusedPanelId == location.containerPanelID else { return false }
            return activeRemoteTmuxControlPane(containerPanelID: location.containerPanelID)?
                .pane.panel.id == surfaceID
        }

        guard let tabID = surfaceIdFromPanelId(surfaceID),
              let paneID = bonsplitController.allPaneIds.first(where: { paneID in
                  bonsplitController.tabs(inPane: paneID).contains(where: { $0.id == tabID })
              }) else { return false }
        return bonsplitController.selectedTab(inPane: paneID)?.id == tabID
            && bonsplitController.focusedPaneId == paneID
    }

    /// Deactivates every projected tmux terminal except the effective target.
    /// Mirror panes are intentionally absent from `Workspace.panels`, so the
    /// ordinary unfocus loop cannot enforce this invariant by itself.
    func unfocusRemoteTmuxControlPanes(except surfaceID: UUID?) {
        for containerPanelID in panels.keys where isRemoteTmuxControlContainer(containerPanelID) {
            for location in remoteTmuxControlPanes(containerPanelID: containerPanelID)
            where location.pane.panel.id != surfaceID {
                location.pane.panel.unfocus()
            }
        }
    }

    /// Resolves the selected terminal target. A mirror container projects its
    /// active inner pane; a requested pane projects that pane's selected surface.
    func controlDefaultTerminalTarget(
        paneID requestedPaneID: UUID?
    ) -> (surfaceID: UUID, panel: TerminalPanel)? {
        if let requestedPaneID {
            if let remote = remoteTmuxControlPane(paneID: requestedPaneID) {
                return (remote.pane.panel.id, remote.pane.panel)
            }
            if let paneID = bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID }),
               let tab = bonsplitController.selectedTab(inPane: paneID),
               let panelID = panelIdFromSurfaceId(tab.id),
               !isRemoteTmuxControlContainer(panelID),
               let panel = terminalPanel(for: panelID) {
                return (panelID, panel)
            }
            return nil
        }

        guard let focusedPanelId,
              let projection = controlSurfaceProjection(forContainerPanelID: focusedPanelId),
              let panel = projection.panel as? TerminalPanel else { return nil }
        return (projection.surfaceID, panel)
    }

    /// Resolves explicit-or-default control-plane surface targeting. An
    /// explicit surface id (or a routed tmux pane's surface) canonicalizes
    /// fail-closed via ``controlSurfaceTarget(for:)``; the focused default
    /// projects a mirror container to its tmux-active pane like
    /// `surface.current`. Returns nil when nothing is focused.
    func controlRequestedSurfaceTarget(
        explicitSurfaceID: UUID?,
        routedPaneID: UUID?
    ) -> (requestedSurfaceID: UUID, target: ControlSurfaceProjection?)? {
        if let explicit = explicitSurfaceID
            ?? routedPaneID.flatMap({ remoteTmuxControlPane(paneID: $0)?.pane.panel.id }) {
            return (explicit, controlSurfaceTarget(for: explicit))
        }
        guard let focusedPanelId else { return nil }
        return (focusedPanelId, controlSurfaceProjection(forContainerPanelID: focusedPanelId))
    }
}
