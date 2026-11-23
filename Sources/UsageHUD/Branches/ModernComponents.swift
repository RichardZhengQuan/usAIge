import AppKit
import SwiftUI

/// Shared sizes for the Modern look's grouped lists.
enum ModernMetrics {
    static let iconSize: CGFloat = 26
    static let rowPadding: CGFloat = 14
    /// Separators start under the text, past the row's icon.
    static let separatorInset: CGFloat = rowPadding + iconSize + 10
    static let cardRadius: CGFloat = 12
}

/// The Modern look's colours: the system's own, so they follow light, dark and
/// Increase Contrast like the rest of macOS.
@available(macOS 14.0, *)
enum ModernPalette {
    static let worktrees = Color(nsColor: .systemPink)
    static let buildCache = Color(nsColor: .systemGreen)
    static let toolStorage = Color(nsColor: .systemOrange)
    static let system = Color(nsColor: .systemGray)
    static let memory = Color(nsColor: .systemPurple)
    static let storage = Color(nsColor: .systemBlue)
    static let free = Color.primary.opacity(0.08)

    /// Grouped page behind the cards, as in System Settings and iOS.
    static let page = Color(nsColor: NSColor(name: "usAIge.modern.page") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.11, alpha: 1)
            : NSColor(calibratedRed: 0.949, green: 0.949, blue: 0.969, alpha: 1)
    })

    /// A card on the grouped page.
    static let card = Color(nsColor: NSColor(name: "usAIge.modern.card") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.17, alpha: 1)
            : NSColor.white
    })

    static func color(for layer: PaperweightLayer) -> Color {
        switch layer.id {
        case "wt": worktrees
        case "cache": buildCache
        case "tool": toolStorage
        case "other", PaperweightData.otherMemoryLayerID: system
        case "free", "mfree": free
        case "dev": Color(nsColor: .systemTeal)
        case "tool-" + AIToolID.claude.rawValue: Color(nsColor: .systemOrange)
        case "tool-" + AIToolID.chatGPT.rawValue: Color(nsColor: .systemIndigo)
        case "tool-" + AIToolID.cursor.rawValue: Color(nsColor: .systemBrown)
        case "tool-" + AIToolID.gemini.rawValue: Color(nsColor: .systemCyan)
        case "tool-" + AIToolID.grok.rawValue: Color(nsColor: .systemGray)
        default: layer.id.hasPrefix("tool-") ? toolColor(layer.id) : Color(nsColor: .systemMint)
        }
    }

    /// Tools without a colour of their own still get distinct ones, picked
    /// steadily from the system palette by name.
    private static func toolColor(_ id: String) -> Color {
        let palette: [NSColor] = [.systemPink, .systemTeal, .systemYellow, .systemGreen, .systemCyan,
                                  .systemPurple, .systemRed, .systemBlue, .systemMint, .systemBrown]
        let index = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff } % palette.count
        return Color(nsColor: palette[index])
    }

    static func symbol(for layer: PaperweightLayer) -> String {
        switch layer.id {
        case "wt": "arrow.triangle.branch"
        case "cache": "hammer.fill"
        case "tool": "shippingbox.fill"
        case "other", PaperweightData.otherMemoryLayerID: "macwindow"
        case "free": "circle.dashed"
        case "mfree": "square.stack.3d.up.fill"
        case "dev": "server.rack"
        default: "sparkles"
        }
    }

    /// How full a disk looks: calm until it is nearly full.
    static func storageColor(usedShare: Double) -> Color {
        if usedShare >= 0.95 { return Color(nsColor: .systemRed) }
        if usedShare >= 0.9 { return Color(nsColor: .systemOrange) }
        return storage
    }
}

/// A symbol on a rounded, coloured square, as in System Settings.
@available(macOS 14.0, *)
struct ModernIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = ModernMetrics.iconSize

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// What a branch or worktree row shows as its icon in the Modern look.
@available(macOS 14.0, *)
enum BoardRowMark {
    static func mark(for item: WorkItem, kind: WorkCard.Kind) -> (symbol: String, color: Color) {
        if kind == .running {
            return item.status == .mainCopy
                ? ("house.fill", Color(nsColor: .systemIndigo))
                : ("play.fill", Color(nsColor: .systemBlue))
        }
        switch item.status {
        case .notSaved: return ("exclamationmark.triangle.fill", Color(nsColor: .systemRed))
        case .pushed: return ("icloud.and.arrow.up.fill", Color(nsColor: .systemOrange))
        case .notChecked: return ("lock.fill", Color(nsColor: .systemOrange))
        case .finished:
            return item.losesIgnoredFiles || !item.eligibility.isAllowed
                ? ("checkmark.shield.fill", Color(nsColor: .systemOrange))
                : ("checkmark", Color(nsColor: .systemGreen))
        case .empty: return ("circle.dashed", Color(nsColor: .systemGray))
        case .folderGone: return ("folder.badge.minus", Color(nsColor: .systemGray))
        case .inUse: return ("play.fill", Color(nsColor: .systemBlue))
        case .mainCopy: return ("house.fill", Color(nsColor: .systemIndigo))
        case .checking: return ("hourglass", Color(nsColor: .systemGray))
        }
    }
}

/// One stretch of a capacity bar.
struct CapacitySegment: Identifiable, Equatable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
    var isMeasuring = false
    var detail: String? = nil
}

/// A capacity bar like iPhone Storage: one rounded bar, a stretch per
/// category, and what's left drawn as the empty track.
@available(macOS 14.0, *)
struct CapacityBar: View {
    let segments: [CapacitySegment]
    let capacity: Int64
    var height: CGFloat = 22
    /// Thin bars on cards read better without gaps between stretches.
    var gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geometry in
            let visible = segments.filter { $0.bytes > 0 }
            let gaps = gap * CGFloat(max(0, visible.count - 1))
            let usable = max(0, geometry.size.width - gaps)
            let total = Double(max(capacity, PaperweightData.total(visible.map(\.bytes)), 1))
            HStack(spacing: gap) {
                ForEach(visible) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(2, usable * CGFloat(Double(segment.bytes) / total)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(ModernPalette.free)
        .clipShape(RoundedRectangle(cornerRadius: min(height * 0.32, 7), style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\($0.title) \(BoardText.bytes($0.bytes))" }.joined(separator: ", "))
    }
}

/// The key under a capacity bar.
@available(macOS 14.0, *)
struct CapacityLegend: View {
    let segments: [CapacitySegment]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(segments) { segment in
                HStack(spacing: 6) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                        .overlay { Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5) }
                    Text(segment.title).foregroundStyle(.secondary)
                    Text(segment.isMeasuring ? "Measuring…" : segment.detail ?? BoardText.bytes(segment.bytes))
                        .monospacedDigit()
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
    }
}

/// A rounded card on the grouped page.
@available(macOS 14.0, *)
struct ModernCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ModernPalette.card, in: RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

/// A titled group of rows. The rows draw their own separators, so the card
/// hides the one above its first row.
@available(macOS 14.0, *)
struct ModernSection<Content: View, Accessory: View>: View {
    let title: String
    var detail: String? = nil
    var footer: String? = nil
    /// A dot before the title, tying the group to its colour in a bar.
    var tint: Color? = nil
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let tint {
                    Circle().fill(tint).frame(width: 9, height: 9).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .overlay(alignment: .top) {
                Rectangle().fill(ModernPalette.card).frame(height: 1)
            }
            .background(ModernPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

@available(macOS 14.0, *)
extension ModernSection where Accessory == EmptyView {
    init(title: String, detail: String? = nil, footer: String? = nil, tint: Color? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, detail: detail, footer: footer, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

/// A quiet row inside a section, for empty states and notes.
@available(macOS 14.0, *)
struct ModernNoteRow: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .frame(width: ModernMetrics.iconSize)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ModernMetrics.rowPadding)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                .padding(.leading, ModernMetrics.separatorInset)
        }
    }
}

/// A row that opens something: icon, title, value and a chevron.
@available(macOS 14.0, *)
struct ModernNavigationRow: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var isExpanded: Bool? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                .padding(.leading, ModernMetrics.separatorInset)
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            ModernIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            if let isExpanded {
                FoldChevron(isExpanded: isExpanded)
            } else if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            }
        }
        .padding(.horizontal, ModernMetrics.rowPadding)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// A small ring gauge, as on Apple Watch and in iOS widgets.
@available(macOS 14.0, *)
struct ModernRingGauge: View {
    let share: Double
    let color: Color
    var lineWidth: CGFloat = 4
    var symbol: String? = nil
    var symbolSize: CGFloat = 11

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(share, share > 0 ? 0.015 : 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// Rows grouped on one card, as in a grouped list. The rows draw their own
/// separators, so the card hides the one above its first row.
@available(macOS 14.0, *)
struct ModernGroupBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(ModernPalette.card).frame(height: 1)
        }
        .background(ModernPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ModernMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }
}

/// A resource drawn as iPhone Storage draws a disk: one capacity bar, and a
/// key whose entries choose the category the list below shows.
@available(macOS 14.0, *)
struct ModernResourceCard: View {
    let configuration: PaperweightConfiguration
    let selectedLayerID: String
    let select: (String) -> Void

    private var layers: [PaperweightLayer] { Self.orderedLayers(configuration) }

    /// Storage reads like iPhone Storage, what usAIge can help with first;
    /// memory reads largest first.
    static func orderedLayers(_ configuration: PaperweightConfiguration) -> [PaperweightLayer] {
        let order = ["wt", "cache", "tool", "other"]
        return configuration.layers.sorted { left, right in
            let l = order.firstIndex(of: left.id) ?? Int.max
            let r = order.firstIndex(of: right.id) ?? Int.max
            if l != r { return l < r }
            return left.bytes == right.bytes ? left.id < right.id : left.bytes > right.bytes
        }
    }

    static func segments(_ configuration: PaperweightConfiguration) -> [CapacitySegment] {
        orderedLayers(configuration).map {
            CapacitySegment(id: $0.id, title: $0.title, bytes: $0.bytes,
                            color: ModernPalette.color(for: $0), isMeasuring: $0.isMeasuring,
                            detail: configuration.amount(for: $0))
        }
    }

    var body: some View {
        ModernCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                CapacityBar(segments: Self.segments(configuration), capacity: configuration.capacityBytes, height: 24)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(layers + [configuration.freeLayer]) { layer in
                        key(layer)
                    }
                }
            }
        }
    }

    private func key(_ layer: PaperweightLayer) -> some View {
        let selected = layer.id == selectedLayerID
        let isFree = layer.id == configuration.freeLayer.id
        return Button { select(layer.id) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isFree ? Color.primary.opacity(0.18) : ModernPalette.color(for: layer))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(layer.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(configuration.amount(for: layer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(layer.title), \(configuration.amount(for: layer))")
        .accessibilityHint("Shows what this category holds")
    }
}

/// One tab of a `ModernTabBar`.
@available(macOS 14.0, *)
struct ModernTab: Identifiable {
    let id: String
    let title: String
    var detail: String? = nil
    let icon: AnyView
}

/// A larger segmented control whose tabs carry a logo, a name and a figure,
/// for choosing what a page lists.
@available(macOS 14.0, *)
struct ModernTabBar: View {
    let tabs: [ModernTab]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    let selected = tab.id == selection
                    Button { withAnimation(.snappy(duration: 0.18)) { selection = tab.id } } label: {
                        HStack(spacing: 8) {
                            tab.icon.frame(width: 18, height: 18)
                            Text(tab.title).font(.callout.weight(.semibold)).lineLimit(1)
                            if let detail = tab.detail {
                                Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ModernPalette.card)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityLabel([tab.title, tab.detail].compactMap { $0 }.joined(separator: ", "))
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
