import SwiftUI

/// Kleines, farbiges Label, das den Build-Channel sichtbar macht —
/// damit ein Tester nicht versehentlich denkt, er sei in Prod.
/// In Prod-Builds rendert das View nichts (`EmptyView`).
struct EnvBadge: View {
    let environment: AppEnvironment

    var body: some View {
        if environment.isNonProduction {
            Text(environment.displayLabel)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(background, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityLabel("Build-Channel \(environment.displayLabel)")
        }
    }

    private var background: Color {
        switch environment {
        case .staging: .orange
        case .dev: .blue
        case .unknown: .gray
        case .production: .clear // unreachable wegen isNonProduction
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        EnvBadge(environment: .dev)
        EnvBadge(environment: .staging)
        EnvBadge(environment: .production) // sollte nichts rendern
        EnvBadge(environment: .unknown)
    }
    .padding()
}
