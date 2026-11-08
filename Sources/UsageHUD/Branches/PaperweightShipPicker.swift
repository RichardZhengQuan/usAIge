import SwiftUI

/// Native submenus keep the full fleet reachable without a screen-height list.
@available(macOS 14.0, *)
struct PaperweightShipPicker: View {
    let selected: PaperweightShipKind
    let choose: (PaperweightShipKind) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Ship")
                .foregroundStyle(.secondary)
            Menu {
                ForEach(PaperweightShipCollection.allCases) { collection in
                    Menu(collection.title) {
                        ForEach(collection.ships) { ship in
                            Button {
                                choose(ship)
                            } label: {
                                if selected == ship {
                                    Label(ship.title, systemImage: "checkmark")
                                } else {
                                    Text(ship.title)
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(selected.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Ship in the front paperweight")
            .accessibilityValue(selected.title)
            .help("Choose a ship for this paperweight. Memory and Storage remember their own choices.")
        }
        .frame(maxWidth: 400, alignment: .leading)
    }
}
