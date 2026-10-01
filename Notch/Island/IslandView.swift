import SwiftUI

/// The root view inside the notch panel. The island hangs from the top centre;
/// everything around it is transparent.
struct IslandView: View {
    @Environment(IslandCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = coordinator.state
        let m = coordinator.metrics
        let ear = Theme.earRadius
        let settings = coordinator.settings

        ZStack(alignment: .top) {
            if showsGlow(state) {
                IslandShape(bottomRadius: m.bottomRadius)
                    .fill(coordinator.waveformTint)
                    .animation(Motion.width(to: state, reduceMotion: reduceMotion)) { $0.frame(width: m.width + 2 * ear) }
                    .animation(Motion.height(to: state, reduceMotion: reduceMotion)) { $0.frame(height: m.height) }
                    .blur(radius: 22)
                    .opacity(0.55)
                    .transition(.opacity.animation(.easeInOut(duration: 0.5)))
            }

            ZStack(alignment: .top) {
                IslandBackground(
                    material: settings.material,
                    bottomRadius: m.bottomRadius,
                    collarHeight: coordinator.notchSize.height,
                    isMinimal: state == .idle || state == .hidden
                )
                .shadow(color: .black.opacity(state.hasShadow && settings.shadowWhenExpanded ? 0.55 : 0), radius: 20, y: 18)

                // Fills the island (inside the ears) and follows its size as it animates,
                // so content is revealed from the top down as the island drops.
                content(for: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: m.bottomRadius, bottomTrailingRadius: m.bottomRadius))
                    .padding(.horizontal, ear)
            }
            .animation(Motion.width(to: state, reduceMotion: reduceMotion)) { $0.frame(width: m.width + 2 * ear) }
            .animation(Motion.height(to: state, reduceMotion: reduceMotion)) { $0.frame(height: m.height) }
            .contentShape(Rectangle())
            .onTapGesture { coordinator.clicked() }
            .keyframeAnimator(initialValue: 1.0, trigger: coordinator.hoverPulse) { view, scale in
                view.scaleEffect(scale, anchor: .top)
            } keyframes: { _ in
                // A quick swell and settle when the pointer arrives.
                CubicKeyframe(1.05, duration: 0.18)
                SpringKeyframe(1.0, duration: 0.6, spring: .init(duration: 0.6, bounce: 0.35))
            }

            if let bubble = state.bubble {
                BubbleView(activity: bubble, size: coordinator.notchSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture { coordinator.clicked(focus: bubble) }
                    .offset(x: m.width / 2 + IslandState.bubbleGap + coordinator.notchSize.height / 2)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }

            if coordinator.showsHoverTitle, let track = coordinator.nowPlaying.track {
                HoverTitle(track: track)
                    .offset(y: m.height + 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.forTransition(to: state, reduceMotion: reduceMotion), value: state)
        .animation(.easeOut(duration: 0.2), value: coordinator.showsHoverTitle)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(for state: IslandState) -> some View {
        ZStack(alignment: .top) {
            switch state {
            case .idle, .hidden:
                Color.clear
            case .compact(let activity), .split(let activity, _):
                CompactActivityView(activity: activity)
            case .peek(let peek):
                PeekView(peek: peek)
            case .expanded(let tab):
                let scale = coordinator.settings.expandedSize.scale
                let base = tab.baseSize(dashboardRows: coordinator.dashboardRows)
                ExpandedView(tab: tab)
                    .frame(width: base.width, height: base.height)
                    .scaleEffect(scale, anchor: .top)
                    .frame(width: base.width * scale, height: base.height * scale, alignment: .top)
            }
        }
        .id(state.contentKind)
        .transition(.islandContent(reduceMotion: reduceMotion))
    }

    /// The artwork glow shows while music is the island's main content and actually playing.
    private func showsGlow(_ state: IslandState) -> Bool {
        guard coordinator.settings.artworkGlow, coordinator.nowPlaying.track?.isPlaying == true else { return false }
        switch state {
        case .compact(.music), .split(.music, _), .expanded(.nowPlaying), .expanded(.lyrics), .peek(.trackChange): return true
        default: return false
        }
    }
}

/// Black (the design), or Liquid Glass on macOS 26+: Glass everywhere, or Hybrid —
/// solid black around the camera, fading into glass below it. Idle stays black so the
/// island still disappears into the notch.
private struct IslandBackground: View {
    let material: IslandMaterial
    let bottomRadius: CGFloat
    let collarHeight: CGFloat
    let isMinimal: Bool

    var body: some View {
        let shape = IslandShape(bottomRadius: bottomRadius)
        if material == .black || isMinimal {
            shape.fill(.black)
        } else if #available(macOS 26, *) {
            ZStack(alignment: .top) {
                Color.clear.glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
                if material == .hybrid {
                    // Sized in points, not gradient stops, so it doesn't shift while the island resizes.
                    VStack(spacing: 0) {
                        Rectangle().fill(.black).frame(height: collarHeight)
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                        Spacer(minLength: 0)
                    }
                    .clipShape(shape)
                }
            }
        } else {
            shape.fill(.black)
        }
    }
}

/// When hovering doesn't expand the island, the song title appears just below it.
private struct HoverTitle: View {
    let track: NowPlayingService.Track

    var body: some View {
        HStack(spacing: 6) {
            Text(track.title).fontWeight(.semibold)
            if !track.artist.isEmpty {
                Text("·").foregroundStyle(.white.opacity(0.4))
                Text(track.artist).foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(maxWidth: 320)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.85), in: Capsule())
        .fixedSize()
    }
}
