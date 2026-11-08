import Darwin
import Foundation

/// macOS's system-wide pressure signal, independent of the AI-process totals
/// shown in the Memory ocean. Unreadable values remain explicitly unknown.
enum SystemMemoryPressure: Equatable, Sendable {
    case unknown, normal, warning, critical

    init(dispatchLevel: UInt32) {
        switch dispatchLevel {
        case UInt32(DispatchSource.MemoryPressureEvent.normal.rawValue): self = .normal
        case UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue): self = .warning
        case UInt32(DispatchSource.MemoryPressureEvent.critical.rawValue): self = .critical
        default: self = .unknown
        }
    }

    static func read() -> Self {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        // This sysctl returns dispatch flags (1/2/4), rather than XNU's
        // internal pressure enum. It needs no process scan or shell command.
        // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0,
              size == MemoryLayout<UInt32>.size else { return .unknown }
        return Self(dispatchLevel: value)
    }
}

/// The weather describes the resource being explored. It never derives system
/// memory pressure from AI-process footprints or a hypothetical clear preview.
struct ResourceWeatherStatus: Equatable, Sendable {
    let weather: CruiseWeather
    let summary: String

    static func make(for resource: PaperweightID, memoryPressure: SystemMemoryPressure,
                     disk: DiskSpace?) -> Self {
        switch resource {
        case .memory:
            switch memoryPressure {
            case .unknown: Self(weather: .cloudy, summary: "Memory pressure unavailable")
            case .normal: Self(weather: .sunny, summary: "Memory pressure normal")
            case .warning: Self(weather: .rain, summary: "Memory pressure elevated")
            case .critical: Self(weather: .storm, summary: "Memory pressure critical")
            }
        case .storage:
            storage(disk)
        }
    }

    func resolvedWeather(preference: CruiseWeather) -> CruiseWeather {
        preference == .automatic ? weather : preference
    }

    private static func storage(_ disk: DiskSpace?) -> Self {
        guard let disk, disk.totalBytes > 0, disk.availableBytes >= 0 else {
            return Self(weather: .cloudy, summary: "Storage status unavailable")
        }
        let freeShare = min(1, Double(disk.availableBytes) / Double(disk.totalBytes))
        let weather: CruiseWeather
        if freeShare <= 0.05 { weather = .storm }
        else if freeShare <= 0.10 { weather = .rain }
        else if freeShare <= 0.20 { weather = .cloudy }
        else { weather = .sunny }
        return Self(weather: weather, summary: "Storage \(Int((freeShare * 100).rounded()))% free")
    }
}
