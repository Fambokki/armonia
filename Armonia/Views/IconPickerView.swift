import SwiftUI
import UIKit

/// Scelta dell'icona dell'app sulla schermata Home.
struct IconPickerView: View {
    private struct AppIconOption: Identifiable {
        let id: String        // nome nel catalogo risorse
        let title: String
        /// nil = icona principale
        var alternateName: String? { id == "AppIcon" ? nil : id }
    }

    private let options: [AppIconOption] = [
        .init(id: "AppIcon", title: "Classica"),
        .init(id: "AppIcon-Notte", title: "Notte"),
        .init(id: "AppIcon-Oceano", title: "Oceano"),
        .init(id: "AppIcon-Tramonto", title: "Tramonto"),
        .init(id: "AppIcon-Menta", title: "Menta"),
        .init(id: "AppIcon-Minimal", title: "Minimal"),
        .init(id: "AppIcon-Vinile", title: "Vinile"),
        .init(id: "AppIcon-Onda", title: "Onda"),
        .init(id: "AppIcon-Neon", title: "Neon"),
        .init(id: "AppIcon-Monogramma", title: "Monogramma"),
    ]

    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(options) { option in
                    let selected = current == option.alternateName
                    Button {
                        select(option)
                    } label: {
                        VStack(spacing: 8) {
                            Image("Preview-\(option.id)")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 76, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .stroke(selected ? Color.accentColor : .white.opacity(0.12),
                                                lineWidth: selected ? 3 : 1)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.white, Color.accentColor)
                                            .offset(x: 6, y: 6)
                                    }
                                }
                            Text(option.title)
                                .font(.caption)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
            }
        }
        .navigationTitle("Icona dell'app")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ option: AppIconOption) {
        guard UIApplication.shared.supportsAlternateIcons else {
            error = "Questo iPhone non permette di cambiare icona."
            return
        }
        guard current != option.alternateName else { return }
        UIApplication.shared.setAlternateIconName(option.alternateName) { err in
            Task { @MainActor in
                if let err {
                    error = "Non è stato possibile cambiare icona: \(err.localizedDescription)"
                } else {
                    error = nil
                    current = option.alternateName
                }
            }
        }
    }
}
