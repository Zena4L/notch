import AppKit
import SwiftUI
import Testing
@testable import Notch

/// Nothing should ever sit behind the camera housing.
@MainActor
struct NotchClearanceTests {
    private func makeCoordinator() -> IslandCoordinator {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "NotchTests-\(UUID())")!)
        return IslandCoordinator(
            settings: settings, battery: BatteryService(), timers: TimerService(),
            nowPlaying: NowPlayingService(settings: settings, startStream: false),
            downloads: DownloadService(settings: settings, storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("NotchTests-\(UUID()).json")),
            calendar: CalendarService(settings: settings)
        )
    }

    @Test(arguments: [CGFloat(185), 190, 200, 230])
    func earsLeaveRoomBesideAnyNotch(notchWidth: CGFloat) {
        let c = makeCoordinator()
        c.notchSize = CGSize(width: notchWidth, height: 37)
        let states: [IslandState] = [
            .compact(.countdown), .compact(.music), .compact(.download),
            .peek(.hud(.volume, level: 50, muted: false)), .peek(.charging(80)), .peek(.timerDone),
        ]
        for state in states {
            let m = state.metrics(notch: c.notchSize, hasNotch: true)
            let ear = Ears<EmptyView, EmptyView>.earWidth(islandWidth: m.width, coordinator: c)
            #expect(ear >= IslandState.minEarContent, "\(state) leaves only \(ear) pt beside a \(notchWidth) pt notch")
        }
    }

    @Test func downloadAndVolumeUseTheSpaceBelowTheNotch() {
        let notch = CGSize(width: 190, height: 37)
        #expect(IslandState.peek(.downloadDone).metrics(notch: notch, hasNotch: true).height == 92)
        #expect(IslandState.peek(.downloadFailed).metrics(notch: notch, hasNotch: true).height == 92)
        #expect(IslandState.compact(.download).metrics(notch: notch, hasNotch: true).height == 37 + IslandState.progressLip)
        #expect(Peek.downloadDone.isInteractive)
    }

    /// Renders the island states to PNGs (with the notch shaded red) for a visual check.
    @Test func renderSnapshots() throws {
        let c = makeCoordinator()
        c.notchSize = CGSize(width: 190, height: 37)
        c.settings.hudEnabled = true
        c.settings.downloadsEnabled = true
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("NotchSnapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let cases: [(String, Peek)] = [
            ("hud-volume", .hud(.volume, level: 65, muted: false)),
            ("hud-muted", .hud(.volume, level: 40, muted: true)),
            ("hud-brightness", .hud(.brightness, level: 30, muted: false)),
            ("download-done", .downloadDone),
            ("download-failed", .downloadFailed),
            ("charging", .charging(80)),
        ]
        for (name, peek) in cases {
            c.show(peek, force: true)
            let view = SnapshotFrame(notch: c.notchSize) { IslandView() }
                .environment(c)
                .frame(width: 560, height: 130)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: out.appendingPathComponent("\(name).png"))
        }
        print("snapshots: \(out.path)")
    }
}

private struct SnapshotFrame<Content: View>: View {
    let notch: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.25)
            content
            // Where the camera housing would be.
            Rectangle().fill(.red.opacity(0.35)).frame(width: notch.width, height: notch.height)
        }
    }
}
