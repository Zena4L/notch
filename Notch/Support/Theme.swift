import SwiftUI

/// Values from the design guide (Notch Island Prototype).
nonisolated enum Theme {
    static let orange = Color(red: 1, green: 159 / 255, blue: 10 / 255)  // #ff9f0a timers
    static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)  // #30d158 charging
    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 1)  // #0a84ff buttons
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)  // #ff453a low battery
    static let secondaryText = Color.white.opacity(0.58)

    /// The concave "ears" that blend the island's top corners into the menu bar.
    static let earRadius: CGFloat = 8

    static let hoverLeaveDelay: Duration = .milliseconds(220)
}

/// Every island animation in one place.
nonisolated enum Motion {
    /// Opening: the design's cubic-bezier(.32,1.28,.48,1) over 0.55 s — a spring with a small overshoot.
    static let open = Animation.spring(duration: 0.55, bounce: 0.28)
    /// Closing settles without overshoot, so the island doesn't bounce back over the menu bar.
    static let close = Animation.spring(duration: 0.45, bounce: 0.02)
    /// Peeks and compact changes.
    static let peek = Animation.spring(duration: 0.5, bounce: 0.18)
    /// With Reduce Motion on, everything just fades quickly.
    static let reduced = Animation.easeInOut(duration: 0.2)

    // The island opens like a drop-down: it widens quickly and without bounce, then drops
    // from the notch with a soft bounce. Closing rolls it back up first, then narrows it.
    // Giving width and height separate springs is what makes the motion read top-to-bottom.

    static func width(to state: IslandState, reduceMotion: Bool) -> Animation {
        if reduceMotion { return reduced }
        return dropsDown(state)
            ? .spring(duration: 0.28, bounce: 0)
            : .spring(duration: 0.42, bounce: 0.04).delay(0.06)
    }

    static func height(to state: IslandState, reduceMotion: Bool) -> Animation {
        if reduceMotion { return reduced }
        return dropsDown(state)
            ? .spring(duration: 0.55, bounce: 0.26).delay(0.05)
            : .spring(duration: 0.34, bounce: 0)
    }

    /// States that hang below the menu bar: the expanded island and the taller peeks.
    private static func dropsDown(_ state: IslandState) -> Bool {
        switch state {
        case .expanded, .peek(.trackChange), .peek(.meeting), .peek(.downloadDone), .peek(.downloadFailed), .peek(.notification): true
        default: false
        }
    }

    static func forTransition(to state: IslandState, reduceMotion: Bool) -> Animation {
        if reduceMotion { return reduced }
        switch state {
        case .expanded: return open
        case .peek: return peek
        default: return close
        }
    }
}

/// Plain island buttons get a soft highlight on hover, like system controls.
struct IslandButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var padding: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(configuration: configuration, cornerRadius: cornerRadius, padding: padding)
    }

    private struct HoverHighlight: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let padding: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(padding)
                .background(
                    .white.opacity(configuration.isPressed ? 0.2 : isHovered ? 0.12 : 0),
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .padding(-padding)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

/// Text that scrolls back and forth when it's too long to fit, pausing at each end.
///
/// The scrolling is a Core Animation keyframe animation, so it runs in the system's render
/// server — Notch itself does no work while a long title glides back and forth.
struct MarqueeText: NSViewRepresentable {
    let text: String
    let size: CGFloat
    var weight: NSFont.Weight = .semibold
    var color: NSColor = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> MarqueeView { MarqueeView() }

    func updateNSView(_ view: MarqueeView, context: Context) {
        view.configure(text: text, font: .systemFont(ofSize: size, weight: weight), color: color, animates: !reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.textWidth, height: ceil(NSFont.systemFont(ofSize: size, weight: weight).boundingRectForFont.height * 0.8))
    }
}

final class MarqueeView: NSView {
    private let textLayer = CALayer()
    private let fade = CAGradientLayer()
    private var configured: (text: String, font: NSFont, color: NSColor, animates: Bool)?
    private(set) var textWidth: CGFloat = 0
    private var textImageSize: CGSize = .zero

    /// Points per second while scrolling, and the pause at each end.
    private static let speed: CGFloat = 30
    private static let pause: CFTimeInterval = 1.5

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(textLayer)
        textLayer.anchorPoint = .zero
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, font: NSFont, color: NSColor, animates: Bool) {
        if let c = configured, c.text == text, c.font == font, c.color == color, c.animates == animates { return }
        configured = (text, font, color, animates)

        // Render the text once into an image; the layer just slides it.
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        textWidth = ceil(size.width)
        textImageSize = CGSize(width: ceil(size.width), height: ceil(size.height))
        let scale = window?.backingScaleFactor ?? 2
        let image = NSImage(size: textImageSize, flipped: false) { rect in
            attributed.draw(at: .zero)
            return true
        }
        textLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        textLayer.contentsScale = scale
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = CGRect(x: 0, y: (bounds.height - textImageSize.height) / 2, width: textImageSize.width, height: textImageSize.height)
        fade.frame = bounds
        CATransaction.commit()
        restartAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let c = configured {
            configured = nil
            configure(text: c.text, font: c.font, color: c.color, animates: c.animates)
        }
    }

    private func restartAnimation() {
        textLayer.removeAnimation(forKey: "marquee")
        let overflow = textWidth - bounds.width
        guard overflow > 1, configured?.animates == true else {
            layer?.mask = nil
            return
        }
        // Fade the edges only while there's something to scroll to.
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.04, 0.96, 1]
        layer?.mask = fade

        let travel = CFTimeInterval(overflow / Self.speed)
        let total = 2 * (travel + Self.pause)
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, 0, -overflow, -overflow, 0]
        animation.keyTimes = [0, Self.pause / total, (Self.pause + travel) / total, (2 * Self.pause + travel) / total, 1].map { NSNumber(value: $0) }
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        animation.duration = total
        animation.repeatCount = .infinity
        textLayer.add(animation, forKey: "marquee")
    }
}

/// How content fades in once the island has started growing: opacity, blur 8 → 0, scale 0.94 → 1.
/// Content slides down into place as it appears (and back up as it goes), blurring in.
private struct BlurScale: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 8 : 0)
            .scaleEffect(active ? 0.96 : 1, anchor: .top)
            .offset(y: active ? -16 : 0)
    }
}

extension AnyTransition {
    static func islandContent(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.linear(duration: 0.01)) }
        return .asymmetric(
            insertion: .modifier(active: BlurScale(active: true), identity: BlurScale(active: false))
                .animation(.spring(duration: 0.45, bounce: 0.12).delay(0.14)),
            removal: .modifier(active: BlurScale(active: true), identity: BlurScale(active: false))
                .animation(.easeIn(duration: 0.14))
        )
    }
}
