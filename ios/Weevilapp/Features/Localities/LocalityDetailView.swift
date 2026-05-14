import SwiftUI

struct LocalityDetailView: View {
    let localityID: String
    @EnvironmentObject var container: AppContainer
    @State private var local: LocalLocality?
    @State private var editing = false

    var body: some View {
        ScrollView {
            if let l = local {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard(l)
                    if !l.notes.isEmpty {
                        GroupBox("Notizen") {
                            Text(l.notes)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle(local?.name.isEmpty == false ? local!.name : "Fundort")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bearbeiten") { editing = true }
                    .disabled(local == nil)
            }
        }
        .task { reload() }
        .sheet(isPresented: $editing, onDismiss: { reload() }) {
            if let l = local {
                LocalityEditView(editing: l)
            }
        }
    }

    @ViewBuilder
    private func headerCard(_ l: LocalLocality) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let lat = l.centroidLat, let lon = l.centroidLon {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.6f, %.6f", lat, lon))
                            .font(.body.monospacedDigit())
                    }
                } else {
                    Text("Keine Koordinate gesetzt")
                        .foregroundStyle(.secondary)
                }
                if let r = l.radiusM {
                    Text("Radius \(Int(r)) m")
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
