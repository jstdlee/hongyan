import SwiftUI

/// The few concepts a new user meets, in the order they meet them.
struct HelpView: View {
    @EnvironmentObject private var model: AppModel

    private struct Concept: Identifiable {
        let id = UUID()
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let concepts: [Concept] = [
        Concept(symbol: "externaldrive.connected.to.line.below", title: "Storage",
                text: "Your own S3-compatible bucket, for example Cloudflare R2. Hongyan needs a key that can read, write and delete."),
        Concept(symbol: "square.stack.3d.up", title: "Backup",
                text: "A full copy of your photo library in one folder. Each backup is complete on its own."),
        Concept(symbol: "calendar", title: "Schedule",
                text: "Hongyan starts a new backup after the number of days you set. iOS picks the exact time."),
        Concept(symbol: "moon.zzz", title: "Background backup",
                text: "iOS uploads the photos for Hongyan, also when the app is closed or the phone is locked."),
        Concept(symbol: "trash", title: "Keep",
                text: "When a new backup is complete, Hongyan deletes the oldest backups above this number."),
        Concept(symbol: "doc.text", title: "Manifest",
                text: "The last file of each backup. A backup without it is not complete, and Hongyan never counts it."),
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "鸿雁传书")
                        .font(.title3.weight(.semibold))
                    Text("Hongyan (鸿雁) is the wild goose of the old saying 鸿雁传书: the goose carries the letter.")
                    Text("Su Wu, a Han envoy, was held by the Xiongnu for 19 years. Then a Han envoy said that the emperor had shot a goose with a letter from Su Wu on its foot. The Xiongnu let Su Wu go home.")
                    Text("Geese fly far, in their season and in order, and they arrive. Hongyan carries your photos the same way: iOS picks the time, and every file arrives.")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } header: {
                Text("About the name")
            }
            Section {
                ForEach(concepts) { concept in
                    row(concept)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { model.isDemo }, set: { model.setDemo($0) })) {
                    RowLabel(title: "Show sample data", detail: "See the app with sample backups. Nothing is uploaded.")
                }
            } header: {
                Text("Demo")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("How Hongyan works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ concept: Concept) -> some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: concept.symbol)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(concept.title).font(.headline)
                    Text(concept.text).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
    }
}
