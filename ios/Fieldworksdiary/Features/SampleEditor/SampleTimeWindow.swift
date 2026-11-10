import FieldworksGeo
import Foundation

/// Editable time fields of a saved sample — begin, end, zone and
/// „Ganztägig“ — with the editing rules shared by the sample editor and
/// the edit form (`SampleFormViewModel`). The instants are UTC; the zone
/// only changes how they are read.
///
/// - The end never lies before the begin (it follows a begin moved past it).
/// - A manual zone choice keeps the instants (source `.manual`). An
///   all-day sample keeps its calendar day instead: its begin moves to
///   00:00 of that day in the new zone.
/// - „Ganztägig“ on: begin = 00:00 of its local day, no end. Off: the
///   Phase Z window (15 minutes) from that begin.
struct SampleTimeWindow: Equatable {
    /// Phase Z window length when „Ganztägig“ is switched off.
    static let defaultLength: TimeInterval = 15 * 60

    private(set) var begin: Date
    /// Shown end; equals `begin` for an all-day sample or a legacy row
    /// without end.
    private(set) var end: Date
    private(set) var timezoneID: String
    private(set) var timezoneSource: TimezoneSource?
    private(set) var isAllDay: Bool

    init(_ sample: LocalSample) {
        begin = sample.beginDate
        end = sample.endDate ?? sample.beginDate
        timezoneID = sample.timezone
        timezoneSource = sample.timezoneSource
        isAllDay = sample.isAllDay
    }

    /// Zone of the sample for display and input.
    var timeZone: TimeZone {
        TimeZone(identifier: timezoneID) ?? TimeZone(identifier: "Europe/Berlin") ?? .current
    }

    /// Sets the begin; the end follows when it would fall before it. An
    /// all-day sample takes 00:00 of the chosen day.
    mutating func setBegin(_ date: Date) {
        if isAllDay {
            begin = SampleTime.startOfDay(date, in: timeZone)
            end = begin
            return
        }
        begin = date
        if end < date { end = date }
    }

    /// Sets the end, never before the begin. Ignored for all-day samples.
    mutating func setEnd(_ date: Date) {
        guard !isAllDay else { return }
        end = max(date, begin)
    }

    /// Manual zone choice; an unknown identifier is ignored.
    mutating func setTimezone(_ identifier: String) {
        guard let newZone = TimeZone(identifier: identifier) else { return }
        guard identifier != timezoneID || timezoneSource != .manual else { return }
        if isAllDay, identifier != timezoneID {
            begin = SampleTime.startOfSameDay(begin, from: timeZone, to: newZone)
            end = begin
        }
        timezoneID = identifier
        timezoneSource = .manual
    }

    /// „Ganztägig“ on: 00:00 of the begin's local day, no end. Off: the
    /// Phase Z default window starting at the current begin (00:00 when
    /// coming from all-day).
    mutating func setAllDay(_ allDay: Bool) {
        guard allDay != isAllDay else { return }
        isAllDay = allDay
        if allDay {
            begin = SampleTime.startOfDay(begin, in: timeZone)
            end = begin
        } else {
            let window = SampleTime.defaultWindow(createdAt: begin, in: timeZone)
            begin = window.begin
            end = window.end
        }
    }

    /// Stored end of this window: nil for all-day.
    var storedEnd: Date? {
        isAllDay ? nil : end
    }

    /// Writes the fields that differ from `base` (the window the user
    /// started from) into `row`, so values written meanwhile (an Ortus
    /// zone) survive an edit of something else. A legacy row without end
    /// keeps it that way until the user moves the window.
    func write(into row: inout LocalSample, base: SampleTimeWindow) {
        if begin != base.begin || end != base.end || isAllDay != base.isAllDay {
            row.beginDate = begin
            row.isAllDay = isAllDay
            if isAllDay {
                row.endDate = nil
            } else if row.endDate != nil || end != begin || base.isAllDay {
                row.endDate = end
            }
        }
        if timezoneID != base.timezoneID || timezoneSource != base.timezoneSource {
            row.timezone = timezoneID
            row.timezoneSource = timezoneSource
        }
    }
}
