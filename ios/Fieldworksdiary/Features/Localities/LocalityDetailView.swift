import SwiftUI

struct LocalityDetailView: View {
    let localityID: String
    @EnvironmentObject var container: AppContainer
    @State private var local: LocalLocality?
    @State private var editing = false

    var body: some View {
        ScrollView {
            if let locality = local {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard(locality)
                    if !locality.notes.isEmpty {
                        GroupBox("Notizen") {
                            Text(locality.notes)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bearbeiten") { editing = true }
                    .disabled(local == nil)
            }
        }
        .task { reload() }
        .sheet(isPresented: $editing, onDismiss: reload) {
            if let locality = local {
                LocalityEditView(editing: locality)
            }
        }
    }

    private var navigationTitleText: String {
        if let name = local?.name, !name.isEmpty { return name }
        return "Fundort"
    }

    private func headerCard(_ locality: LocalLocality) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let lat = locality.centroidLat, let lon = locality.centroidLon {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(String(format: "%.6f, %.6f", lat, lon))
                            .font(.body.monospacedDigit())
                    }
                } else {
                    Text("Keine Koordinate gesetzt")
                        .foregroundStyle(.secondary)
                }
                if let radius = locality.radiusM {
                    Text("Radius \(Int(radius)) m")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reload() {
        local = (try? container.localitiesStore.fetchById(localityID))
    }
}
