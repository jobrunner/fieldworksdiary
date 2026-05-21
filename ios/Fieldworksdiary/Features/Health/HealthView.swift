import SwiftUI

struct HealthView: View {
    @EnvironmentObject var config: AppConfig
    @StateObject private var checker = HealthChecker()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Circle()
                    .fill(checker.status.color)
                    .frame(width: 96, height: 96)
                    .accessibilityLabel(Text(checker.status.label))
                Text(checker.status.label)
                    .font(.title2.weight(.semibold))
                if !checker.detail.isEmpty {
                    Text(checker.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Button("Erneut prüfen") {
                    Task { await checker.check(endpoint: config.endpointURL) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(config.endpointURL.isEmpty)
            }
            .padding()
            .navigationTitle("Status")
            .task { await checker.check(endpoint: config.endpointURL) }
            .onChange(of: config.endpointURL) { _, _ in
                Task { await checker.check(endpoint: config.endpointURL) }
            }
        }
    }
}
