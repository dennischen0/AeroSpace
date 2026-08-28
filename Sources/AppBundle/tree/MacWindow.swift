import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        // The on-screen list must include this brand new window before anything reads window levels,
        // otherwise getWindowLevel returns nil for it and isWindowHeuristic misclassifies it as a popup
        invalidateWindowLevelCache()
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        // A new native macOS tab appears as a brand new AXWindow, but it is not a new logical window.
        // It joins a tab group that already occupies a slot in the layout, so on-window-detected
        // callbacks must not run for it. https://github.com/nikitabobko/AeroSpace/issues/68
        let tabGroupMembership = try await classifyTabGroupMembership(windowId: windowId, macApp: macApp)
        // A window that joins a tab group, and a window not yet classifiable, are both kept out of the
        // layout. For the join that is because the group already owns a slot; for the undecided case it
        // is because being tiled would let the layout pass at the end of this session move it and its
        // sibling apart, and the frame match that identifies a tab would then never succeed again
        let data: BindingData = if tabGroupMembership.isJoin || tabGroupMembership.isUndecided {
            BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        } else {
            try await unbindAndGetBindingDataForNewWindow(
                windowId,
                macApp,
                isStartup
                    ? (rect?.center.monitorApproximation ?? mainMonitorInfo).activeWorkspace
                    : focus.workspace,
                window: nil,
                .cancellable,
            )
        }

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        allWindowsMap[windowId] = window
        if case .joinsTabGroup(let sibling) = tabGroupMembership {
            // Membership is only ever established here, at the one moment it is observable
            let groupId = sibling.tabGroupId ?? sibling.windowId
            sibling.tabGroupId = groupId
            window.tabGroupId = groupId
        }

        try await debugWindowsIfRecording(window, .cancellable)
        // Must run on every single registration, and must never be gated on anything: it is the first
        // line of defence against the lock screen, and restoreTreeRecursive deliberately bails out
        // mid-tree when a window isn't registered yet, so the frozen world is only fully restored by
        // the pass that registers the last window
        let restoredFrozenWorld = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window)
        switch tabGroupMembership {
            case .joinsTabGroup:
                break // Not a new logical window. Don't run on-window-detected callbacks for it
            case .standaloneWindow:
                if !restoredFrozenWorld { await tryOnWindowDetected(window) }
            case .undecided:
                // The window server hasn't committed the new window yet. Decide on a later refresh
                // session, once its frame exists. See resolveDeferredWindowDetection
                if !restoredFrozenWorld { windowsPendingDetection[windowId] = 0 }
        }
        return window
    }

    enum TabGroupMembership {
        case joinsTabGroup(sibling: MacWindow)
        case standaloneWindow
        /// Not observable yet
        case undecided

        var isJoin: Bool { if case .joinsTabGroup = self { true } else { false } }
        var isUndecided: Bool { if case .undecided = self { true } else { false } }
    }

    /// Tabs of one native tab group share the exact frame of the group, which is what links a newly
    /// appeared AXWindow to the tab it was opened next to.
    ///
    /// The link is not observable at the instant the AXWindow appears. Measured on macOS 26: a new
    /// tab is first reported with a 0x0 frame while the tab it replaces is still listed as on-screen,
    /// and only once the window server commits the new frame does the replaced tab drop out of the
    /// on-screen list. Both are consequences of the same commit, so a materialized frame is the
    /// condition that makes the answer knowable — deciding before that classifies every ⌘T on a
    /// single-tab window as a brand new window. https://github.com/nikitabobko/AeroSpace/issues/68
    @MainActor
    static func classifyTabGroupMembership(windowId: UInt32, macApp: MacApp) async throws -> TabGroupMembership {
        if isUnitTest { return .standaloneWindow }
        guard let rect = try await macApp.getAxRect(windowId, .cancellable), rect.width > 0, rect.height > 0 else {
            return .undecided
        }
        // Deliberately NOT Window.tabVisibility. That predicate asks whether some *registered* window
        // of the app is on screen, and the window being registered here isn't in allWindowsMap yet, so
        // it can never be its own sibling — which made ⌘T on a single-window app undetectable. At
        // creation time the on-screen sibling is known: it is this window
        guard getWindowLevel(for: windowId) != nil else { return .undecided }
        for candidate in allWindows where candidate.app.pid == macApp.pid && candidate.windowId != windowId {
            guard getWindowLevel(for: candidate.windowId) == nil else { continue } // Must be off screen
            // A minimized window is off screen too, and is not a tab
            if try await candidate.isMacosMinimized(.cancellable) { continue }
            // Frame equality is the whole signal. There is deliberately no "the app has exactly one
            // off-screen window" fallback: plenty of apps keep one around, and guessing there silently
            // suppresses the user's on-window-detected callbacks for genuinely new windows
            if let candidateRect = try await candidate.getAxRect(.cancellable), candidateRect.isApproximatelyEqual(to: rect) {
                return .joinsTabGroup(sibling: candidate)
            }
        }
        return .standaloneWindow
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel, cm)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel, cm)
    }

    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        handOverTabGroupSlot()
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }
    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }

    @MainActor override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitor else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect(.cancellable) else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                prevUnhiddenProportionalPositionInsideWorkspaceRect =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
                if isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize(.cancellable) else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitor.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitor.visibleRect.bottomRightCorner - onePixelOffset
        }
        setAxFrame(p, nil)
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitor.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // https://github.com/nikitabobko/AeroSpace/issues/1519
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), nil)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await macApp.getAxSize(windowId, cm)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        try await macApp.getAxRect(windowId, cm)
    }
}

extension Rect {
    /// AX reports tab frames with sub-pixel jitter, so exact equality is too strict
    func isApproximatelyEqual(to other: Rect) -> Bool {
        abs(topLeftX - other.topLeftX) < 2 && abs(topLeftY - other.topLeftY) < 2 &&
            abs(width - other.width) < 2 && abs(height - other.height) < 2
    }
}

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        let data = forceTile
            ? unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(self.asMacWindow().windowId, self.asMacWindow().macApp, workspace, window: self, cm)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewWindow(_ windowId: UInt32, _ macApp: MacApp, _ workspace: Workspace, window: Window?, _ cm: CancellationMode) async throws -> BindingData {
    let windowLevel = getWindowLevel(for: windowId)
    return switch try await macApp.getAxUiElementWindowType(windowId, windowLevel, cm) {
        case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog: BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window: unbindAndGetBindingDataForNewTilingWindow(workspace, window: window)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    let mruWindow = workspace.mostRecentWindowRecursive
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        return BindingData(
            parent: tilingParent,
            adaptiveWeight: WEIGHT_AUTO,
            index: mruWindow.ownIndex.orDie() + 1,
        )
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

/// Windows whose on-window-detected callbacks are deferred because it wasn't yet observable whether
/// they are a new logical window or a new native tab, and how many sessions each has waited.
/// See ``MacWindow/classifyTabGroupMembership``
@MainActor var windowsPendingDetection: [UInt32: Int] = [:]

/// Some apps keep windows that never get a frame at all (Calendar and Firefox each hold 0x0 windows
/// on this machine), so waiting for one cannot be unbounded
private let maxDeferredDetectionSessions = 10

/// Runs once per refresh session, so the decision is driven by the app's own event flow rather than by
/// a fixed delay
@MainActor
func resolveDeferredWindowDetection() async throws {
    for (windowId, sessions) in windowsPendingDetection {
        guard let window = MacWindow.allWindowsMap[windowId] else {
            windowsPendingDetection.removeValue(forKey: windowId) // Died before it could be classified
            continue
        }
        // Claim the entry before the first suspension point, or two overlapping sessions can both get
        // past the classification and both run the callbacks
        windowsPendingDetection.removeValue(forKey: windowId)
        let membership = try await MacWindow.classifyTabGroupMembership(windowId: windowId, macApp: window.macApp)
        if membership.isUndecided && sessions < maxDeferredDetectionSessions {
            windowsPendingDetection[windowId] = sessions + 1
            continue
        }
        if case .joinsTabGroup(let sibling) = membership {
            // Membership established late, but at the first moment it was observable
            let groupId = sibling.tabGroupId ?? sibling.windowId
            sibling.tabGroupId = groupId
            window.tabGroupId = groupId
            continue // normalizeTabGroups hands the group's slot to whichever member is on screen
        }
        // Unconditional and never gated — see the note in getOrRegister. Redundant with the call made
        // at registration only if nothing happened in between, and a lock screen in between is exactly
        // the case that has to keep working
        let restoredFrozenWorld = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window)
        // A genuine new window, or one we gave up waiting on. It was kept out of the layout while
        // undecided, so it needs a real place now — on the same workspace getOrRegister would have
        // chosen for it, which at startup is its monitor's, not the focused one
        if window.parent === macosPopupWindowsContainer {
            let rect = try await window.getAxRect(.cancellable)
            let workspace = isStartup
                ? (rect?.center.monitorApproximation ?? mainMonitorInfo).activeWorkspace
                : focus.workspace
            try await window.relayoutWindow(on: workspace, .cancellable)
        }
        if !restoredFrozenWorld { await tryOnWindowDetected(window) }
    }
}

@MainActor
func tryOnWindowDetected(_ window: Window) async {
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
        case .macosPopupWindowsContainer, .unbound:
            break
    }
}

@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async -> Int32ExitCode {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    var lastExitCode = Int32ExitCode.succ
    for callback in config.onWindowDetected where await callback.matches(window) {
        lastExitCode = await callback.run.run(env.withWindowId(window.windowId), io)
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
}

extension WindowDetectedCallback {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        switch self.matcher {
            case .legacy(let matcher):
                if let startupMatcher = matcher.duringAeroSpaceStartup, startupMatcher != isStartup {
                    return false
                }
                if let regex = matcher.windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: regex) != true {
                    return false
                }
                if let appId = matcher.appId, appId != window.app.rawAppBundleId {
                    return false
                }
                if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
                    return false
                }
                if let workspace = matcher.workspace, workspace != window.nodeWorkspace?.name {
                    return false
                }
                return true
            case .command(let command):
                return await command.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin).exitCode.rawValue == 0
        }
    }
}
