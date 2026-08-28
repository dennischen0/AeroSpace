import CoreGraphics
import Foundation

@MainActor
private var cache: [UInt32: MacOsWindowLevel] = [:]
@MainActor
private var isCacheFresh = false

/// Must be called at least once per refresh session. Otherwise, a window that *changed* its
/// on-screen state (e.g. a native macOS tab that just went to the background) is reported stale
/// forever, because a cache hit never re-queries the window server.
///
/// Callers that must observe a *brand new* window (window detection) have to invalidate explicitly,
/// because absence from a cache that is merely "fresh for this session" is otherwise indistinguishable
/// from a window that appeared after the last query
@MainActor
func invalidateWindowLevelCache() {
    isCacheFresh = false
    isBoundsCacheFresh = false
}

/// `nil` means that the window is absent from the on-screen window list. See ``normalizeTabGroups()``
///
/// The whole list is queried at most once per refresh session: the window server call is expensive
/// (it returns every window of every app), and absence must not cost an extra call per window
@MainActor
func getWindowLevel(for windowId: UInt32) -> MacOsWindowLevel? {
    if !isCacheFresh { refreshCache() }
    return cache[windowId]
}


/// Frames of *all* windows, on screen or not. The window server reports these for background native
/// tabs too, which lets steady-state tab matching compare frames without a single AX round trip
@MainActor
private var boundsCache: [UInt32: Rect] = [:]
@MainActor
private var isBoundsCacheFresh = false

@MainActor
func getWindowBounds(for windowId: UInt32) -> Rect? {
    if !isBoundsCacheFresh { refreshBoundsCache() }
    return boundsCache[windowId]
}

@MainActor
private func refreshBoundsCache() {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionAll)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return }
    var result: [UInt32: Rect] = [:]
    for elem in cfArray {
        let dict = elem as NSDictionary
        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value
        guard let bounds = dict[kCGWindowBounds] as? NSDictionary,
              let x = (bounds["X"] as? NSNumber)?.doubleValue,
              let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else { continue }
        result[windowId] = Rect(topLeftX: x, topLeftY: y, width: width, height: height)
    }
    boundsCache = result
    isBoundsCacheFresh = true
}

@MainActor
private func refreshCache() {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return }
    var result: [UInt32: MacOsWindowLevel] = [:]
    for elem in cfArray {
        let dict = elem as NSDictionary

        guard let _windowLayer = dict[kCGWindowLayer] else { continue }
        let windowLayer = ((_windowLayer as! CFNumber) as NSNumber).intValue

        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value

        result[windowId] = .new(windowLevel: windowLayer)
    }
    cache = result
    isCacheFresh = true
}

enum MacOsWindowLevel: Sendable, Equatable {
    case normalWindow
    case alwaysOnTopWindow
    case unknown(windowLevel: Int)

    static func new(windowLevel: Int) -> MacOsWindowLevel {
        switch windowLevel {
            case 0: .normalWindow
            case 3: .alwaysOnTopWindow
            default: .unknown(windowLevel: windowLevel)
        }
    }

    static func fromJson(_ json: Json) -> MacOsWindowLevel? {
        switch json {
            case .string("normalWindow"): .normalWindow
            case .string("alwaysOnTopWindow"): .alwaysOnTopWindow
            case .int(let int): .new(windowLevel: Int(exactly: int).orDie())
            default: nil
        }
    }

    func toJson() -> Json {
        switch self {
            case .normalWindow: .string("normalWindow")
            case .alwaysOnTopWindow: .string("alwaysOnTopWindow")
            case .unknown(let layerNumber): .int(layerNumber)
        }
    }
}
