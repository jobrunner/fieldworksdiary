import FieldworksGeo
import SwiftUI

/// Zweistufige Zeitzonenwahl für ein Sample: erst die Region (Präfix der
/// IANA-Kennung vor dem ersten „/“), dann die Zonen dieser Region. Die
/// aktuelle Zone ist mit Häkchen markiert. Gedacht für den Bearbeiten-
/// Dialog; eine Auswahl ruft `onSelect` und schließt das Blatt.
struct TimeZonePickerView: View {
    /// IANA-Kennung der aktuell gesetzten Zone.
    let selected: String
    /// Zeitpunkt, für den die Kürzel (Sommer-/Winterzeit) gelten.
    let date: Date
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RegionList(selected: selected, date: date) { id in
                onSelect(id)
                dismiss()
            }
            .navigationTitle("Zeitzone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}

/// Gruppierung der bekannten Zonen nach Region. Rein, damit testbar.
enum TimeZoneCatalog {
    static let otherRegion = "Sonstige"

    /// Region einer Kennung: Präfix vor dem ersten „/“.
    static func region(of identifier: String) -> String {
        guard let slash = identifier.firstIndex(of: "/") else { return otherRegion }
        return String(identifier[..<slash])
    }

    /// Regionen alphabetisch.
    static func regions(_ identifiers: [String] = TimeZone.knownTimeZoneIdentifiers) -> [String] {
        Array(Set(identifiers.map(region(of:)))).sorted()
    }

    /// Zonen einer Region alphabetisch.
    static func zones(in region: String, _ identifiers: [String] = TimeZone.knownTimeZoneIdentifiers) -> [String] {
        identifiers.filter { self.region(of: $0) == region }.sorted()
    }

    /// Lesbarer Name ohne Region: „America/Argentina/Buenos_Aires“ → „Argentina/Buenos Aires“.
    static func displayName(_ identifier: String) -> String {
        let rest = identifier.firstIndex(of: "/").map { String(identifier[identifier.index(after: $0)...]) } ?? identifier
        return rest.replacingOccurrences(of: "_", with: " ")
    }
}

private struct RegionList: View {
    let selected: String
    let date: Date
    let onSelect: (String) -> Void

    var body: some View {
        List(TimeZoneCatalog.regions(), id: \.self) { region in
            NavigationLink {
                ZoneList(region: region, selected: selected, date: date, onSelect: onSelect)
            } label: {
                HStack {
                    Text(region)
                    if TimeZoneCatalog.region(of: selected) == region {
                        Spacer(minLength: AppSpacing.sm)
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
            }
            .accessibilityLabel(region)
            .accessibilityValue(TimeZoneCatalog.region(of: selected) == region ? "enthält die gewählte Zeitzone" : "")
            .accessibilityHint("Zeigt die Zeitzonen dieser Region.")
        }
    }
}

private struct ZoneList: View {
    let region: String
    let selected: String
    let date: Date
    let onSelect: (String) -> Void

    var body: some View {
        List(TimeZoneCatalog.zones(in: region), id: \.self) { id in
            let isSelected = id == selected
            Button {
                onSelect(id)
            } label: {
                HStack {
                    Text(TimeZoneCatalog.displayName(id))
                        .foregroundStyle(.primary)
                    Spacer(minLength: AppSpacing.sm)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(label(for: id))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .navigationTitle(region)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func label(for id: String) -> String {
        guard let tz = TimeZone(identifier: id) else { return id }
        return SampleTime.timezoneLabel(tz, at: date)
    }
}

#Preview("Standard") {
    TimeZonePickerView(selected: "Atlantic/Canary", date: Date()) { _ in }
}

#Preview("AX5") {
    TimeZonePickerView(selected: "Europe/Berlin", date: Date()) { _ in }
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dunkel") {
    TimeZonePickerView(selected: "Asia/Kolkata", date: Date()) { _ in }
        .preferredColorScheme(.dark)
}
