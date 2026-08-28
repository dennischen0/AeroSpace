import AppKit

/// Native macOS tabs. A background tab is a tracked window absent from its app's `AXWindows`.
/// A tab group owns exactly one layout slot. https://github.com/nikitabobko/AeroSpace/issues/68
@MainActor
func normalizeNativeTabs() async throws {
    var byPid: [Int32: [MacWindow]] = [:]
    for window in MacWindow.allWindows {
        byPid[window.app.pid, default: []].append(window)
    }

    for (_, windows) in byPid {
        guard let app = windows.first?.macApp else { continue }
        let axWindowIds = app.axWindowIds
        if axWindowIds.isEmpty { continue } // Unobservable (lock screen). Don't conclude anything

        // Sorted because allWindows is dictionary-ordered
        let sorted = windows.sorted { $0.windowId < $1.windowId }
        let vacating = sorted.filter { !axWindowIds.contains($0.windowId) && $0.holdsLayoutSlot }
        // Must be `isParkedNativeTab`, not merely slotless: real popups are slotless too
        var needSlot = sorted.filter { axWindowIds.contains($0.windowId) && $0.isParkedNativeTab && !$0.holdsLayoutSlot }

        for tab in vacating {
            // Two groups switching at once would otherwise pair positionally and swap slots permanently
            if vacating.count > 1, let tabRect = try await tab.getAxRect(.cancellable) {
                for (i, candidate) in needSlot.enumerated() {
                    if let rect = try await candidate.getAxRect(.cancellable), rect.isSameFrame(as: tabRect) {
                        needSlot.swapAt(0, i)
                        break
                    }
                }
            }
            // Find the successor before touching the tree. Parking without one discards the slot, and a
            // parked window absent from AXWindows is in neither needSlot nor validateStillPopups, so it
            // never comes back. Leaving it in place costs one session and is self-correcting
            var successor: MacWindow?
            if let heir = needSlot.first {
                needSlot.removeFirst()
                successor = heir
            } else {
                successor = try await findMisplacedFrontTab(of: tab, among: sorted, axWindowIds)
            }
            guard let successor else { continue }
            // Unbind the successor first: it may share the tab's parent, and reading the tab's index
            // before the successor is removed leaves the index one too high. Read the slot at the instant
            // of the swap, since normalizeContainers() invalidates a stored (parent, index)
            successor.unbindFromParent()
            successor.claimTabGroupSlot(tab.unbindFromParent())
            park(tab)
        }

        // Nothing vacated: these are real windows, owed the callbacks registration withheld. Gated on
        // surviving one pass because the sibling's demotion may not land until the next session
        for window in needSlot {
            if window.tabParkSessions < 1 {
                window.tabParkSessions += 1
                continue
            }
            let workspace = window.parkedFromWorkspace.flatMap { Workspace.get(byName: $0) } ?? focus.workspace
            let owesCallback = window.tabCallbackWithheld
            window.clearTabParkState()
            try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
            // Only a window whose callbacks were withheld at registration is owed them. A tab demoted by
            // park() already fired its own, so firing here would run the user's rules on a tab switch
            if owesCallback { await tryOnWindowDetected(window) }
        }
    }
}

/// The replacing tab, tiled at registration instead of parked. Frame match is a tie-break within an
/// already-identified set, so it can mis-order but not mis-classify
@MainActor
private func findMisplacedFrontTab(
    of tab: MacWindow,
    among windows: [MacWindow],
    _ axWindowIds: Set<UInt32>,
) async throws -> MacWindow? {
    guard let tabRect = try await tab.getAxRect(.cancellable) else { return nil }
    for candidate in windows
        where candidate.windowId != tab.windowId
        && axWindowIds.contains(candidate.windowId)
        && candidate.holdsLayoutSlot
    {
        guard let rect = try await candidate.getAxRect(.cancellable), rect.isSameFrame(as: tabRect) else { continue }
        // `accordion` gives every window in a container the same frame, so require tabbedness too
        guard try await candidate.macApp.nativeTabCount(candidate.windowId, .cancellable).map({ $0 >= 2 }) == true else { continue }
        return candidate
    }
    return nil
}

@MainActor
private func park(_ window: MacWindow) {
    if let workspace = window.nodeWorkspace { window.parkedFromWorkspace = workspace.name }
    window.isParkedNativeTab = true
    window.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
}

extension Window {
    @MainActor
    var holdsLayoutSlot: Bool {
        parent != nil && parent !== macosPopupWindowsContainer
    }

    @MainActor
    func clearTabParkState() {
        isParkedNativeTab = false
        parkedFromWorkspace = nil
        tabParkSessions = 0
        tabCallbackWithheld = false
    }

    @MainActor
    func claimTabGroupSlot(_ slot: BindingData) {
        clearTabParkState()
        bind(to: slot.parent, adaptiveWeight: slot.adaptiveWeight, index: slot.index)
    }
}

extension MacWindow {
    @MainActor
    var isMacosBackgroundTab: Bool {
        let axWindowIds = macApp.axWindowIds
        return !axWindowIds.isEmpty && !axWindowIds.contains(windowId)
    }

    /// Runs while the window is still bound so a tab group keeps its slot when its front tab closes.
    @MainActor
    func handOverNativeTabSlot() {
        guard holdsLayoutSlot, let parent, let index = ownIndex else { return }
        // No AX call here. getAxRectForTermination blocks the main actor on a dying app's AX thread
        let heir = MacWindow.allWindows
            .filter { $0.windowId != windowId && $0.app.pid == app.pid && $0.isParkedNativeTab }
            .min { $0.windowId < $1.windowId }
        guard let heir else { return }
        heir.clearTabParkState()
        heir.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
    }
}

extension Rect {
    func isSameFrame(as other: Rect) -> Bool {
        abs(topLeftX - other.topLeftX) < 2 && abs(topLeftY - other.topLeftY) < 2 &&
            abs(width - other.width) < 2 && abs(height - other.height) < 2
    }
}
