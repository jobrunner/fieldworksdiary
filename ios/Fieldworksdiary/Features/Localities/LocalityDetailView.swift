import SwiftUI

struct LocalityDetailView: View {
    let localityID: String
    @EnvironmentObject var container: AppContainer
    @State private var local: LocalLocality?
    @State private var placemark: LocalPlacemark?
    @State private var editing = false
    @State private var editingPlacemark = false

    var body: some View {
        ScrollView {
            if let locality = local {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard(locality)
                    placemarkCard
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
        .task {
            reload()
            await refreshPlacemark()
        }
        .sheet(isPresented: $editing, onDismiss: {
            reload()
            Task { await refreshPlacemark() }
        }) {
            if let locality = local {
                LocalityEditView(editing: locality)
            }
        }
        .sheet(isPresented: $editingPlacemark) {
            PlacemarkEditSheet(
                localityID: localityID,
                existing: placemark,
                onSaved: handlePlacemarkSaved,
                onCleared: handlePlacemarkCleared
            )
        }
    }

    /// PATCH returned a (possibly new) placemark: cache it, re-point
    /// the local locality relation, and show it immediately.
    private func handlePlacemarkSaved(_ pm: Placemark) {
        try? container.placemarksStore.upsert(pm)
        try? container.localitiesStore.setPlacemark(localityID: localityID, placemarkID: pm.id)
        reload()
        placemark = try? container.placemarksStore.fetch(backendID: pm.id)
    }

    /// Override cleared: detach locally. The backend's auto-geocode
    /// hook repopulates on the next locality update; until the next
    /// pull the address simply shows as unset.
    private func handlePlacemarkCleared() {
        try? container.localitiesStore.setPlacemark(localityID: localityID, placemarkID: nil)
        reload()
        placemark = nil
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

    /// "Adresse"-Sektion: rendert die per Backend-Auto-Geocode oder
    /// Manual-Override gefüllten Placemark-Felder. Komplett still
    /// gerendert, wenn die Locality (noch) kein Placemark hat — der
    /// Auto-Geocode-Hook läuft asynchron, also kommt der erste Render
    /// gelegentlich vor dem ersten Placemark.
    @ViewBuilder
    private var placemarkCard: some View {
        if let pm = placemark {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "house.lodge")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Adresse")
                            .font(.subheadline.weight(.semibold))
                        if pm.geocodingSource == "manual" {
                            Text("manuell")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                                .accessibilityLabel("manuell gesetzt")
                        }
                        Spacer()
                        Button {
                            editingPlacemark = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel("Adresse bearbeiten")
                    }
                    placemarkLines(pm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if local?.placemark != nil {
            // Locality verweist auf eine Placemark, aber lokal noch
            // kein Cache-Hit — dezente Ladeanzeige.
            GroupBox {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Adresse wird ermittelt …")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Keine Adresse — Einstieg zum manuellen Setzen anbieten.
            GroupBox {
                Button {
                    editingPlacemark = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "house.lodge")
                            .accessibilityHidden(true)
                        Text("Adresse manuell setzen")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func placemarkLines(_ pm: LocalPlacemark) -> some View {
        if !pm.countryISO.isEmpty {
            // Ortus place (Phase O2): country-specific terms per level.
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(PlaceDisplay.fields(pm.place)) { item in
                    PlaceFieldRow(item)
                }
            }
        } else {
            legacyPlacemarkLines(pm)
        }
    }

    /// Pre-Ortus address fields (legacy rows until the O3 backfill).
    private func legacyPlacemarkLines(_ pm: LocalPlacemark) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            if let n = pm.name, !n.isEmpty {
                Text(n).font(.body.weight(.medium))
            }
            if let t = pm.thoroughfare, !t.isEmpty {
                Text(t).font(.body)
            }
            HStack(spacing: 6) {
                if let pc = pm.postalCode, !pc.isEmpty {
                    Text(pc).font(.body.monospacedDigit())
                }
                if let loc = pm.locality, !loc.isEmpty {
                    Text(loc).font(.body)
                }
            }
            if let sub = pm.subLocality, !sub.isEmpty {
                Text(sub).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(pm.country).font(.footnote)
                if let admin = pm.administrativeArea, !admin.isEmpty {
                    Text("·").font(.footnote)
                    Text(admin).font(.footnote)
                }
                if let sub = pm.subAdministrativeArea, !sub.isEmpty {
                    Text("·").font(.footnote)
                    Text(sub).font(.footnote)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func reload() {
        local = (try? container.localitiesStore.fetchById(localityID))
    }

    /// Loads the placemark cached locally first; if missing, pulls
    /// from the backend and writes the row through to the cache.
    /// Errors silently — UI just stays in the "wird ermittelt"
    /// state.
    private func refreshPlacemark() async {
        guard let pmID = local?.placemark, !pmID.isEmpty else {
            placemark = nil
            return
        }
        if let cached = try? container.placemarksStore.fetch(backendID: pmID) {
            placemark = cached
            return
        }
        let endpoint = container.config.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }
        do {
            let client = PlacemarkClient(endpoint: endpoint, auth: container.auth)
            let remote = try await client.fetch(id: pmID)
            try? container.placemarksStore.upsert(remote)
            placemark = try? container.placemarksStore.fetch(backendID: pmID)
        } catch {
            Log.network.error("placemark fetch failed: \(error.localizedDescription)")
        }
    }
}
