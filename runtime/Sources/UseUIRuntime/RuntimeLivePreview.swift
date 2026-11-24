import UseUIProtocol
import Foundation

/// The local viewer follows only observations that the session has published successfully.
@MainActor
final class RuntimeLivePreview {
    private lazy var panel = LivePreviewPanel()
    private var anchor: DesktopActivity?
    private var currentSource: LivePreviewTarget?

    nonisolated init() {}

    nonisolated func follow(_ observation: Observation, target: Target?, onlyIfDifferent: Bool = false) {
        guard let pid = Int32(exactly: observation.target.pid) else { return }
        // Semantic traversal publishes only objects owned by the exact retained window.
        let sheets = observation.elements.filter { $0.role == "AXSheet" }
        let selective = observation.axSelection?.selectors.contains {
            $0.role == "AXSheet" && $0.identifier == nil && $0.label == nil
        } == false
        let activity = DesktopActivity.observing(observation)
        let title = target?.title ?? ""
        DispatchQueue.main.async {
            let sameWindow = self.anchor?.target == activity.target && self.anchor?.bounds == activity.bounds
            if onlyIfDifferent && sameWindow { return }
            let sheetBounds: Rect?
            if sheets.count == 1 { sheetBounds = sheets[0].bounds }
            else if sheets.isEmpty && selective && sameWindow { sheetBounds = self.currentSource?.sheetBounds }
            else { sheetBounds = nil }
            let descriptor = LivePreviewTarget(processId: pid, windowId: observation.target.windowId,
                bounds: observation.windowBounds, sheetBounds: sheetBounds)
            self.anchor = activity
            self.currentSource = descriptor
            self.panel.follow(descriptor, title: title)
        }
    }

    func present(_ activity: DesktopActivity) { panel.activity(activity) }

    nonisolated func submit(_ activity: DesktopActivity) {
        DispatchQueue.main.async { self.present(activity) }
    }

    nonisolated func recover(_ phase: DesktopActivity.Phase, target: TargetKey) {
        DispatchQueue.main.async {
            if let anchor = self.anchor, anchor.target == target { self.present(anchor.withPhase(phase)) }
        }
    }

    nonisolated func toggle() {
        DispatchQueue.main.async {
            if self.panel.isVisible {
                self.panel.dismiss()
            } else {
                self.panel.showIfPossible()
            }
        }
    }

    nonisolated func dismiss() {
        DispatchQueue.main.async {
            self.anchor = nil
            self.currentSource = nil
            self.panel.dismiss()
        }
    }
}
