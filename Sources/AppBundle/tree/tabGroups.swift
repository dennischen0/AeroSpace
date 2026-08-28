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
    try await formTabGroups()

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
        guard let front = onScreen.first else {
            // No *member* is on screen. Two very different situations, and they need opposite handling.
            //
            // If some other window of the same app is on screen, it is the group's real front tab and
            // it is holding the slot — the members were matched to each other without it, which is what
            // happens when the front tab is corner-parked on a hidden workspace, or when a minimized
            // tab group is restored and the fronted tab's frame no longer matches its siblings. Every
            // member is then a background tab, and a background tab must never hold a slot of its own.
            //
            // If nothing of the app is on screen, the whole app is off screen (lock screen, display
            // sleep, cmd+H) and nothing is knowable, so change nothing.
            //
            // Known open case: a group on another macOS Space has a genuinely off-screen front tab, so
            // an unrelated on-screen window of the same app makes this true and parks the whole group,
            // leaving it holding no slot. It recovers when that Space is visited
            let pid = members.first?.app.pid
            let appHasOnScreenWindow = MacWindow.allWindows.contains {
                $0.app.pid == pid && getWindowLevel(for: $0.windowId) != nil
            }
            if appHasOnScreenWindow {
                for member in members
                    where member.parent != nil && member.parent !== macosPopupWindowsContainer
                {
                    park(member)
                }
            }
            continue
        }

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
                front.parkedFromWorkspace = nil
                park(holder)
            }
        } else {
            // The group holds no slot at all (every member was parked). Give the front tab a normal one
            try await front.relayoutWindow(on: tabGroupWorkspace(members), .cancellable, forceTile: true)
        }

        for member in members where member.windowId != front.windowId {
            if member.parent != nil && member.parent !== macosPopupWindowsContainer { park(member) }
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
        member.parkedFromWorkspace = nil
    }
}

/// The workspace the group lives on, taken from whichever member still holds a place in the tree.
/// Falling back to the focused workspace when every member is parked is a guess, but dragging a group
/// that lives on another workspace over to the focused one is not
@MainActor
private func tabGroupWorkspace(_ members: [MacWindow]) -> Workspace {
    let sorted = members.sorted { $0.windowId < $1.windowId }
    if let workspace = sorted.lazy.compactMap({ $0.nodeWorkspace }).first { return workspace }
    // Every member is parked, so none has a nodeWorkspace. Where they were parked from is a far better
    // answer than whichever workspace the user happens to be looking at
    if let workspace = sorted.lazy.compactMap({ $0.parkedFromWorkspace }).compactMap({ Workspace.get(byName: $0) }).first {
        return workspace
    }
    return focus.workspace
}

/// Records the workspace before unbinding, because a parked window has no `nodeWorkspace`
@MainActor
private func park(_ window: MacWindow) {
    if let workspace = window.nodeWorkspace { window.parkedFromWorkspace = workspace.name }
    window.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
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

/// Membership can only be *established* at creation while a window is on screen, and a background tab
/// is off screen by definition. So every tab that already existed when its window was registered —
/// everything open at AeroSpace startup, and everything re-registered after an unlock or a restart —
/// would never be grouped, and would sit in the layout as a stray window.
///
/// This closes that by letting groups form in steady state as well. It is the fail-open direction, so
/// it carries the same guards that make creation-time matching safe, and one more: frames are compared
/// using the window server's own numbers rather than AX, so the scan costs nothing until a pair
/// actually matches
@MainActor
private func formTabGroups() async throws {
    var ungroupedByPid: [Int32: [MacWindow]] = [:]
    for window in MacWindow.allWindows where window.tabGroupId == nil {
        ungroupedByPid[window.app.pid, default: []].append(window)
    }

    for (_, windows) in ungroupedByPid where windows.count > 1 {
        let onScreen = windows.filter { getWindowLevel(for: $0.windowId) != nil }
            .sorted { $0.windowId < $1.windowId }
        let offScreen = windows.filter { getWindowLevel(for: $0.windowId) == nil }
            .sorted { $0.windowId < $1.windowId }

        try await matchAgainstFrontTab(onScreen: onScreen, offScreen: offScreen)
        try await clusterOffScreenTabs(offScreen)
    }
}

/// The front tab of a group is on screen and its background tabs are not, so an off-screen window
/// sharing the on-screen window's exact frame is a tab of that group.
///
/// Only works while the group's front tab still reports the group's frame, i.e. on the visible
/// workspace. `hideInCorner` breaks it everywhere else, which is what ``clusterOffScreenTabs`` covers
@MainActor
private func matchAgainstFrontTab(onScreen: [MacWindow], offScreen: [MacWindow]) async throws {
    if offScreen.isEmpty { return }
    for front in onScreen {
        guard let frontRect = getWindowBounds(for: front.windowId), frontRect.width > 0, frontRect.height > 0 else { continue }
        // A native-fullscreen window sits on its own Space, and the app's other windows are off screen
        // because of that rather than because they are tabs. Its frame is the whole display, so it
        // wouldn't match a tiled sibling anyway — this is belt and braces
        if try await front.isMacosFullscreen(.cancellable) { continue }

        for candidate in offScreen where candidate.tabGroupId == nil {
            guard let rect = getWindowBounds(for: candidate.windowId),
                  rect.isApproximatelyEqual(to: frontRect) else { continue }
            guard try await isPlausibleBackgroundTab(candidate) else { continue }
            let groupId = front.tabGroupId ?? front.windowId
            front.tabGroupId = groupId
            candidate.tabGroupId = groupId
        }
    }
}

/// Two or more off-screen windows of one app sharing an exact frame are a tab group.
///
/// This is the only evidence available for a group that isn't on the visible workspace: `hideInCorner`
/// moves the group's *front* tab to the corner every layout pass and never touches the background tabs,
/// so the front tab's frame stops matching its own siblings while theirs stay mutually consistent.
///
/// Deliberately does not require the app to have an on-screen window. Requiring one is what stopped
/// this from firing when a whole app is off screen, which is the case it exists for.
///
/// Must run *after* ``matchAgainstFrontTab``: stamping `tabGroupId` here first would hide every
/// clustered window from that pass, and a group's own front tab could never join it
@MainActor
private func clusterOffScreenTabs(_ offScreen: [MacWindow]) async throws {
    // While the screen is locked every window drops off the on-screen list, including the ones
    // hideInCorner parked — and those all share the *same* top-left with their size unchanged, so any
    // two same-size windows of one app would present byte-identical frames and cluster falsely
    if offScreen.count < 2 || isScreenLocked { return }

    var byFrame: [String: [MacWindow]] = [:]
    // `offScreen` was computed before matchAgainstFrontTab ran, so it still lists windows that pass
    // claimed. The `tabGroupId == nil` filter is what keeps this correct — it is not redundant, and
    // dropping it reintroduces the bug where a group's front tab can never join its own group
    for window in offScreen where window.tabGroupId == nil {
        guard let rect = getWindowBounds(for: window.windowId), rect.width > 0, rect.height > 0 else { continue }
        // CGWindowList numbers come straight from the window server and carry none of AX's sub-pixel
        // jitter, so exact bucketing is right here
        let key = "\(Int(rect.topLeftX))_\(Int(rect.topLeftY))_\(Int(rect.width))_\(Int(rect.height))"
        byFrame[key, default: []].append(window)
    }

    for (_, cluster) in byFrame where cluster.count > 1 {
        var members: [MacWindow] = []
        for window in cluster.sorted(by: { $0.windowId < $1.windowId }) {
            if try await isPlausibleBackgroundTab(window) { members.append(window) }
        }
        // Two survivors are the minimum evidence. A lone window is never assumed to be a tab
        guard members.count > 1, let groupId = members.first?.windowId else { continue }
        for member in members { member.tabGroupId = groupId }
    }
}

/// A minimized window keeps its pre-minimize frame, which under tiling can legitimately equal the frame
/// of whatever took its slot — so this check is load-bearing rather than defensive. Only ever called on
/// a window that already matched a frame, so the AX round trips are paid rarely
@MainActor
private func isPlausibleBackgroundTab(_ window: MacWindow) async throws -> Bool {
    if try await window.isMacosMinimized(.cancellable) { return false }
    if try await window.isMacosFullscreen(.cancellable) { return false }
    return !window.macAppUnsafe.nsApp.isHidden
}

/// The same check MacApp uses as its second line of defence against the lock screen
@MainActor
private var isScreenLocked: Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId
}
