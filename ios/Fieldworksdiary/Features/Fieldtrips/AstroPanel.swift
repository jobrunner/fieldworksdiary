import SwiftUI

struct AstroPanel: View {
    let astro: Astro
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sunSection
            Divider()
            moonSection
            Divider()
            duringFieldtripSection
        }
    }

    // MARK: - Sun

    private var sunSection: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sonne").font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    if let sunrise = astro.sunrise {
                        Label(format(sunrise), systemImage: "sunrise.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    if let sunset = astro.sunset {
                        Label(format(sunset), systemImage: "sunset.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.body.monospacedDigit())
                if let dawn = astro.civilDawn, let dusk = astro.civilDusk {
                    Text("Bürgerliche Dämmerung \(format(dawn)) – \(format(dusk))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Moon

    private var moonSection: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: moonIcon)
                .foregroundStyle(.indigo)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mond").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    if let name = astro.moonPhaseName, !name.isEmpty {
                        Text(name)
                    }
                    Text(String(format: "%.0f %% beleuchtet", astro.moonIllumination * 100))
                        .foregroundStyle(.secondary)
                }
                .font(.body)
                HStack(spacing: 12) {
                    if let rise = astro.moonRise {
                        Label("Aufgang \(format(rise))", systemImage: "arrow.up")
                    }
                    if let set = astro.moonSet {
                        Label("Untergang \(format(set))", systemImage: "arrow.down")
                    }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - During the fieldtrip

    private var duringFieldtripSection: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: astro.moonAboveHorizonDuringFieldtrip ? "moon.fill" : "moon")
                .foregroundStyle(astro.moonAboveHorizonDuringFieldtrip ? .yellow : .secondary)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Während der Exkursion").font(.subheadline.weight(.semibold))
                if astro.moonAboveHorizonDuringFieldtrip {
                    Text(presenceLabel(maxAlt: astro.moonAltitudeMaxDuringDeg))
                        .font(.body)
                    Text(String(format: "max. Mondhöhe %.1f°", astro.moonAltitudeMaxDuringDeg))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Mond war nicht über dem Horizont.")
                        .font(.body)
                }
            }
        }
    }

    // MARK: - Helpers

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func presenceLabel(maxAlt: Double) -> String {
        switch maxAlt {
        case ..<0: return "Mond war nicht über dem Horizont."
        case 0 ..< 10: return "Mond war anwesend, niedrig stehend."
        case 10 ..< 30: return "Mond war anwesend, mittlere Höhe."
        default: return "Mond war hochstehend — Lichtfang erschwert."
        }
    }

    private var moonIcon: String {
        // Map phase 0..1 to a system icon. Approximate.
        let p = astro.moonPhase
        switch p {
        case 0 ..< 0.05, 0.95 ... 1.0: return "moonphase.new.moon"
        case 0.05 ..< 0.20: return "moonphase.waxing.crescent"
        case 0.20 ..< 0.30: return "moonphase.first.quarter"
        case 0.30 ..< 0.45: return "moonphase.waxing.gibbous"
        case 0.45 ..< 0.55: return "moonphase.full.moon"
        case 0.55 ..< 0.70: return "moonphase.waning.gibbous"
        case 0.70 ..< 0.80: return "moonphase.last.quarter"
        default: return "moonphase.waning.crescent"
        }
    }
}
