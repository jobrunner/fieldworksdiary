import FieldworksGeo
import SwiftUI

/// Group „Zeit“ of the edit form: „Beginn“, „Ende“, „Zeitzone“,
/// „Ganztägig“. The pickers read and write in the sample's zone; with
/// „Ganztägig“ only the date is shown and there is no end. The rules
/// live in `SampleTimeWindow`; this view only shows the values and
/// reports changes. Form rows are at least 44 pt high on their own.
struct TimeGroupView: View {
    let begin: Date
    let end: Date
    let timezoneID: String
    let timeZone: TimeZone
    let isAllDay: Bool
    let onBegin: (Date) -> Void
    let onEnd: (Date) -> Void
    let onTimezone: (String) -> Void
    let onAllDay: (Bool) -> Void

    @State private var showingTimeZonePicker = false

    var body: some View {
        Section {
            DatePicker(
                "Beginn",
                selection: Binding(get: { begin }, set: onBegin),
                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
            )
            if !isAllDay {
                DatePicker(
                    "Ende",
                    selection: Binding(get: { end }, set: onEnd),
                    in: begin...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
            Button {
                showingTimeZonePicker = true
            } label: {
                HStack {
                    Text("Zeitzone")
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer(minLength: AppSpacing.sm)
                    Text(timezoneID)
                        .foregroundStyle(AppColor.textSecondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right")
                        .font(AppFont.footnote)
                        .foregroundStyle(AppColor.textSecondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zeitzone")
            .accessibilityValue(timezoneID)
            .accessibilityHint("Öffnet die Auswahl der Zeitzone. Die Zeitpunkte bleiben gleich.")
            .accessibilityAddTraits(.isButton)
            Toggle("Ganztägig", isOn: Binding(get: { isAllDay }, set: onAllDay))
        } header: {
            Text("Zeit")
        } footer: {
            if isAllDay {
                Text("Ganztägig: gespeichert wird nur das Datum, ohne Uhrzeit und Ende.")
            }
        }
        .environment(\.timeZone, timeZone)
        .sheet(isPresented: $showingTimeZonePicker) {
            TimeZonePickerView(selected: timezoneID, date: begin, onSelect: onTimezone)
        }
    }
}

private struct TimeGroupPreview: View {
    @State private var begin = Date()
    @State private var end = Date().addingTimeInterval(SampleTimeWindow.defaultLength)
    @State private var allDay = false
    private let zoneID = "Atlantic/Canary"

    var body: some View {
        Form {
            TimeGroupView(
                begin: begin, end: end, timezoneID: zoneID,
                timeZone: TimeZone(identifier: zoneID) ?? .current, isAllDay: allDay,
                onBegin: { begin = $0 }, onEnd: { end = $0 }, onTimezone: { _ in },
                onAllDay: { allDay = $0 }
            )
        }
    }
}

#Preview("Standard") {
    TimeGroupPreview()
}

#Preview("AX5") {
    TimeGroupPreview()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dunkel") {
    TimeGroupPreview()
        .preferredColorScheme(.dark)
}
