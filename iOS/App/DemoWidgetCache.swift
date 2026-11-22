#if DEBUG
import Foundation
import WidgetKit

/// Debug builds launched with `-usaigeDemo` also hand the sample readings to
/// the home-screen widget, so the widget can be checked in the Simulator
/// without a paired Mac.
enum DemoWidgetCache {
    static func writeIfNeeded() async {
        guard UsageDemoData.isEnabled else { return }
        let now = Date()
        let snapshots = UsageDemoData.snapshots(now: now)
        let metadata = Set(snapshots.map(\.toolID)).map {
            RefreshScheduleMetadata(toolID: $0).recordingSuccess(at: now, refreshIntervalMinutes: 15)
        }
        try? await SharedQuotaCache().save(
            QuotaCacheState(snapshots: snapshots, refreshMetadata: metadata, savedAt: now)
        )
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
