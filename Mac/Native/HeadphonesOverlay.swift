import AppKit
import SwiftUI

private final class HeadphonesPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class HeadphonesOverlay {
    private let panel: HeadphonesPanel
    private var dismissTask: Task<Void, Never>?

    init() {
        panel = HeadphonesPanel(contentRect: NSRect(x: 0, y: 0, width: 268, height: 78),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Громкость наушников GoXLR"
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func show(level: Int) {
        guard (0...255).contains(level) else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        panel.contentView = NSHostingView(rootView: HeadphonesVolumeView(level: level))
        panel.setFrame(NSRect(x: area.midX - 134, y: area.minY + 48, width: 268, height: 78), display: true)
        panel.orderFrontRegardless()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_100_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel.orderOut(nil)
    }
}

private struct HeadphonesVolumeView: View {
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "headphones").font(.system(size: 21))
                Text("Наушники · \(HeadphonesController.percent(level))%")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(.white)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color(red: 0.51, green: 0.75, blue: 0.97))
                        .frame(width: geometry.size.width * CGFloat(level) / 255)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 24)
        .frame(width: 268, height: 78)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.12, green: 0.13, blue: 0.15).opacity(0.96)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Наушники, \(HeadphonesController.percent(level)) процентов")
    }
}
