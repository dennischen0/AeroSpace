import AppKit

/// Native macOS tab groups.
///
/// macOS exposes every tab of a tab group as its own AXWindow, and nothing in any public or private
/// API says that two AXWindows are tabs of the same window — CGWindowList and SkyLight both describe a
/// background tab exactly like an ordinary window, apart from on-screen membership.
///
/// The one moment membership *is* observable is creation: a tab is born sharing the exact frame of the
/// group it joins. ``MacWindow/classifyTabGroupMembership`` catches that moment, and the group is then
/// remembered here. Remembering matters for correctness, not just speed: it makes the feature fail
/// closed. A window that was never seen joining a group can never be parked, so an ordinary window
/// that merely goes off-screen — a Space switch, a native-fullscreen window on another Space, anything
/// neither obvious nor anticipated — is not at risk.
///
/// A group owns exactly one slot in the layout. Whichever member is currently on screen occupies it;
/// the rest are parked outside the tree.
///
/// https://github.com/nikitabobko/AeroSpace/issues/68
@MainActor
func normalizeTabGroups() async throws {
    var groups: [UInt32: [MacWindow]] = [:]
    for window in MacWindow.allWindows {
        if let groupId = window.tabGroupId { groups[groupId, default: []].append(window) }
    }

    for (_, members) in groups {
        if members.count < 2 {
            try await dissolve(members) // A group of one is just a window
            continue
        }
        let onScreen = members.filter { getWindowLevel(for: $0.windowId) != nil }
        // Tabs of one group are mutually exclusive on the on-screen list by construction, so two of
        // them being on it at once proves the grouping no longer holds — the user dragged a tab out
        // into its own window, or "Merge All Windows" reshuffled things
        if onScreen.count > 1 {
            try await dissolve(members)
            continue
        }
        // No member on screen: the whole app is off screen (lock screen, display sleep, Space
        // transition, cmd+H). Nothing is knowable, so change nothing
        guard let front = onScreen.first else { continue }

        // members comes from allWindowsMap.values, whose order is not stable between runs. Every
        // selection here has to be deterministic or the group's slot moves at random
        let holder = members
            .filter { $0.parent != nil && $0.parent !== macosPopupWindowsContainer }
            .min { $0.windowId < $1.windowId }
        if let holder {
            if holder.windowId != front.windowId {
                // Hand the slot over in place. Reading it at the instant of the swap — rather than
                // storing it when the tab was parked — is what keeps this correct across
                // normalizeContainers(), which flattens single-child containers between sessions.
                // It also means `front` inherits the holder's workspace for free
                let slot = holder.unbindFromParent()
                front.bind(to: slot.parent, adaptiveWeight: slot.adaptiveWeight, index: slot.index)
                holder.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            }
        } else {
            // The group holds no slot at all (every member was parked). Give the front tab a normal one
            try await front.relayoutWindow(on: tabGroupWorkspace(members), .cancellable, forceTile: true)
        }

        for member in members where member.windowId != front.windowId {
            if member.parent != nil && member.parent !== macosPopupWindowsContainer {
                member.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            }
        }
    }
}

@MainActor
private func dissolve(_ members: [MacWindow]) async throws {
    let workspace = tabGroupWorkspace(members)
    for member in members.sorted(by: { $0.windowId < $1.windowId }) {
        member.tabGroupId = nil
        // A window that is no longer a tab must not be left parked outside the layout
        if member.parent === macosPopupWindowsContainer {
            try await member.relayoutWindow(on: workspace, .cancellable, forceTile: true)
        }
    }
}

/// The workspace the group lives on, taken from whichever member still holds a place in the tree.
/// Falling back to the focused workspace when every member is parked is a guess, but dragging a group
/// that lives on another workspace over to the focused one is not
@MainActor
private func tabGroupWorkspace(_ members: [MacWindow]) -> Workspace {
    members.sorted { $0.windowId < $1.windowId }
        .lazy
        .compactMap { $0.nodeWorkspace }
        .first ?? focus.workspace
}

extension MacWindow {
    /// Called while the window is still bound, so the group doesn't silently lose its place in the
    /// layout when the member holding it dies (closing the front tab of a group, most commonly)
    @MainActor
    func handOverTabGroupSlot() {
        guard let groupId = tabGroupId else { return }
        tabGroupId = nil
        let survivors = MacWindow.allWindows.filter { $0.windowId != windowId && $0.tabGroupId == groupId }
        // Prefer the member macOS actually brought to the front; otherwise pick deterministically,
        // because allWindows is dictionary-ordered
        let heir = survivors.first { getWindowLevel(for: $0.windowId) != nil }
            ?? survivors.min { $0.windowId < $1.windowId }
        guard let heir else { return }
        if survivors.count == 1 { heir.tabGroupId = nil }
        guard let parent, parent !== macosPopupWindowsContainer, let index = ownIndex else { return }
        // Bound at this window's index while it is still there; it is unbound immediately after, which
        // leaves the heir in its place. The exact adaptive weight is not recoverable without unbinding
        // first, and unbinding here would break the caller's own unbind
        heir.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
    }
}
