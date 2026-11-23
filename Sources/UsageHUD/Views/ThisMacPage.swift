import SwiftUI

/// Available in the main window and the compact interface on older Macs.
struct ThisMacPage: View {
    let liveWork: LiveWorkMonitor?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This Mac")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if let liveWork {
                    ThisMacCPUSection(monitor: liveWork.cpu)
                    ThisMacMemorySection(monitor: liveWork)
                } else {
                    Text("System readings are unavailable.").foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}

private struct ThisMacCPUSection: View {
    @ObservedObject var monitor: SystemCPUMonitor

    var body: some View {
        GroupBox(label: Label("CPU", systemImage: "cpu")) {
            VStack(alignment: .leading, spacing: 10) {
                if let usage = monitor.usage {
                    Text("\(LiveWorkText.percent(usage.busy)) in use")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    ProgressView(value: usage.busy)
                        .accessibilityLabel("CPU usage")
                        .accessibilityValue(LiveWorkText.percent(usage.busy))
                    Divider()
                    SystemReadingRow(title: "User", value: LiveWorkText.percent(usage.user))
                    SystemReadingRow(title: "System", value: LiveWorkText.percent(usage.system))
                    SystemReadingRow(title: "Idle", value: LiveWorkText.percent(usage.idle))
                } else {
                    Text("Waiting for a CPU sample…").foregroundColor(.secondary)
                }
                Text("\(ProcessInfo.processInfo.activeProcessorCount) logical cores")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }
}

private struct ThisMacMemorySection: View {
    @ObservedObject var monitor: LiveWorkMonitor

    var body: some View {
        GroupBox(label: Label("Memory", systemImage: "memorychip")) {
            VStack(alignment: .leading, spacing: 10) {
                if let memory = monitor.memoryUsage {
                    SystemReadingRow(title: "Total in use", value: memory.compactTotal)
                    SystemReadingRow(title: "Physical RAM", value: memory.ramDescription)
                    SystemReadingRow(title: "Swap", value: memory.swapDescription)
                } else {
                    Text("Memory reading unavailable.").foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }
}

private struct SystemReadingRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value).font(.body.monospacedDigit()).foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
