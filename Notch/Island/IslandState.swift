import CoreGraphics

enum IslandTab: Hashable {
    case dashboard, nowPlaying, lyrics, downloads, timer

    /// The tab's content size at the Default expanded size, from the design guide.
    /// The dashboard grows with its number of widget rows.
    func baseSize(dashboardRows: Int = 2) -> CGSize {
        switch self {
        case .timer: CGSize(width: 540, height: 176)
        case .lyrics: CGSize(width: 540, height: 300)
        case .nowPlaying, .downloads: CGSize(width: 540, height: 212)
        case .dashboard: CGSize(width: 540, height: DashboardLayout.height(rows: dashboardRows))
        }
    }
}

/// Something ongoing that keeps the island open in its compact form.
/// The order of `allCases` is the default priority.
enum Activity: String, CaseIterable, Hashable {
    case music, countdown, stopwatch, download
}

/// A short-lived event that briefly opens the island, then lets it collapse again.
enum Peek: Hashable {
    case charging(Int)
    case unplugged(Int)
    case lowBattery(Int)
    case timerDone
    case trackChange
    case meeting
    /// Volume or brightness, as a percentage.
    case hud(HUDService.Kind, level: Int, muted: Bool)
    case downloadDone
    case downloadFailed

    /// Peeks with buttons stay open while the pointer is over them.
    var isInteractive: Bool {
        switch self {
        case .meeting, .downloadDone, .downloadFailed: true
        default: false
        }
    }

    var duration: Duration {
        switch self {
        case .meeting: .seconds(6)
        case .downloadDone, .downloadFailed: .seconds(5)
        case .hud: .milliseconds(1500)
        default: .seconds(3)
        }
    }

    /// For Settings › Try it.
    init?(previewName: String) {
        switch previewName {
        case "charging": self = .charging(80)
        case "unplugged": self = .unplugged(80)
        case "lowBattery": self = .lowBattery(10)
        case "timerDone": self = .timerDone
        case "trackChange": self = .trackChange
        case "meeting": self = .meeting
        case "volume": self = .hud(.volume, level: 60, muted: false)
        case "downloadDone": self = .downloadDone
        default: return nil
        }
    }
}

/// Every shape the island can take. Priority: hidden > expanded > peek > ongoing activities > idle.
enum IslandState: Hashable {
    /// Tucked away completely, e.g. over a full-screen app.
    case hidden
    case idle
    case compact(Activity)
    /// Two activities at once: the first takes the island, the second gets a detached bubble.
    case split(Activity, Activity)
    case peek(Peek)
    case expanded(IslandTab)

    struct Metrics {
        var width: CGFloat
        var height: CGFloat
        var bottomRadius: CGFloat
    }

    struct LayoutOptions {
        var compactStyle: CompactStyle = .beside
        var expandedScale: CGFloat = 1
        var dashboardRows = 2
    }

    static let bubbleGap: CGFloat = 14
    /// How far the "lip" (a level or progress strip along the bottom edge) drops below the notch.
    static let hudLip: CGFloat = 14
    /// Ear layout: padding at the island's outer edges, a gap before the camera housing,
    /// and the least room either side that content needs.
    static let earPadding: CGFloat = 14
    static let notchClearance: CGFloat = 4
    static let minEarContent: CGFloat = 37  // 190 pt notch + 2 × (14 + 4 + 37) = the design's 300 pt
    static let progressLip: CGFloat = 9
    /// Height of the content band in the "below the notch" compact style.
    static let belowBandHeight: CGFloat = 28

    /// Sizes in points, from the design guide. `notch` is the real notch (or menu bar) size.
    func metrics(notch: CGSize, hasNotch: Bool, options: LayoutOptions = .init()) -> Metrics {
        let h = notch.height
        /// The design's widths assume a ~190 pt notch; on Macs with a wider one, grow so each
        /// side still has room and nothing ends up behind the camera.
        func fit(_ design: CGFloat) -> CGFloat {
            guard hasNotch else { return design }
            return max(design, notch.width + 2 * (Self.earPadding + Self.notchClearance + Self.minEarContent))
        }
        switch self {
        case .hidden:
            return Metrics(width: notch.width, height: 0, bottomRadius: 0)
        case .idle:
            // On a display without a notch the idle island is fully hidden.
            return hasNotch
                ? Metrics(width: notch.width, height: h, bottomRadius: 12)
                : Metrics(width: 120, height: 0, bottomRadius: 0)
        case .compact, .split:
            if options.compactStyle == .below {
                return Metrics(width: max(notch.width + 40, 230), height: h + Self.belowBandHeight, bottomRadius: 16)
            }
            switch self {
            case .compact(.music):
                return Metrics(width: fit(316), height: h, bottomRadius: 13)
            case .compact(.download), .split(.download, _):
                return Metrics(width: fit(300), height: h + Self.progressLip, bottomRadius: 15)
            default:
                return Metrics(width: fit(300), height: h, bottomRadius: 13)
            }
        case .peek(.timerDone):
            return Metrics(width: fit(300), height: h, bottomRadius: 13)
        case .peek(.hud):
            // A little wider than other compact states: an icon and a percentage either side.
            return Metrics(width: max(fit(300), notch.width + 128), height: h + Self.hudLip, bottomRadius: 17)
        case .peek(.charging), .peek(.unplugged), .peek(.lowBattery):
            return Metrics(width: fit(408), height: h, bottomRadius: 13)
        case .peek(.downloadDone), .peek(.downloadFailed):
            return Metrics(width: 430, height: 92, bottomRadius: 26)
        case .peek(.trackChange):
            return Metrics(width: 430, height: 92, bottomRadius: 26)
        case .peek(.meeting):
            return Metrics(width: 456, height: 108, bottomRadius: 28)
        case .expanded(let tab):
            let s = options.expandedScale
            let size = tab.baseSize(dashboardRows: options.dashboardRows)
            return Metrics(width: size.width * s, height: size.height * s, bottomRadius: 34 * s)
        }
    }

    var isExpanded: Bool {
        if case .expanded = self { true } else { false }
    }

    /// States that grow below the menu bar float above content, so they cast a shadow.
    var hasShadow: Bool {
        switch self {
        case .expanded, .peek(.trackChange), .peek(.meeting), .peek(.downloadDone), .peek(.downloadFailed): true
        default: false
        }
    }

    var bubble: Activity? {
        if case .split(_, let secondary) = self { secondary } else { nil }
    }

    /// Content only cross-fades when the *kind* of state changes — not when a tab,
    /// battery level, or the split bubble changes.
    var contentKind: String {
        switch self {
        case .hidden: "hidden"
        case .idle: "idle"
        case .compact(let a), .split(let a, _): "compact-\(a)"
        case .peek(.charging): "peek-charging"
        case .peek(.unplugged): "peek-unplugged"
        case .peek(.lowBattery): "peek-low"
        case .peek(.timerDone): "peek-timer-done"
        case .peek(.trackChange): "peek-track"
        case .peek(.meeting): "peek-meeting"
        case .peek(.hud(let kind, _, _)): "peek-hud-\(kind)"
        case .peek(.downloadDone): "peek-download-done"
        case .peek(.downloadFailed): "peek-download-failed"
        case .expanded: "expanded"
        }
    }
}

/// Packs dashboard widgets into rows of four slots (small = 1, wide = 2).
enum DashboardLayout {
    static let slots = 4
    static let rowHeight: CGFloat = 92
    static let spacing: CGFloat = 10
    /// Band (37) + top and bottom padding around the grid.
    static let chrome: CGFloat = 37 + 8 + 16

    static func rows(_ widgets: [DashboardWidget], maxRows: Int) -> [[DashboardWidget]] {
        var rows: [[DashboardWidget]] = []
        var current: [DashboardWidget] = [], used = 0
        for widget in widgets {
            if used + widget.width > slots {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(widget)
            used += widget.width
        }
        if !current.isEmpty { rows.append(current) }
        return Array(rows.prefix(max(1, maxRows)))
    }

    static func height(rows: Int) -> CGFloat {
        let n = CGFloat(max(1, rows))
        return chrome + n * rowHeight + (n - 1) * spacing
    }
}
