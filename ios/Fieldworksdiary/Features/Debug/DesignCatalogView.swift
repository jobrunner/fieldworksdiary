#if DEBUG
    import SwiftUI

    /// The "see-everything-at-once" hub for the design system. Lists
    /// every token and every atom in echt so you can spot drift, test
    /// Dynamic Type / Dark Mode, and discover what's available before
    /// reaching for a magic number.
    ///
    /// Only compiled into DEBUG builds — the `#if` keeps it out of the
    /// App-Store bundle entirely.
    struct DesignCatalogView: View {
        var body: some View {
            List {
                Section("Farben") {
                    NavigationLink("Brand") { ColorSwatchListView(swatches: brandSwatches) }
                    NavigationLink("Surfaces") { ColorSwatchListView(swatches: surfaceSwatches) }
                    NavigationLink("Text") { ColorSwatchListView(swatches: textSwatches) }
                    NavigationLink("Status") { ColorSwatchListView(swatches: statusSwatches) }
                    NavigationLink("Sync-States") { ColorSwatchListView(swatches: syncSwatches) }
                }
                Section("Spacing") {
                    NavigationLink("4pt-Skala") { SpacingScaleView() }
                }
                Section("Radius") {
                    NavigationLink("Corner-Radii") { RadiusScaleView() }
                }
                Section("Typografie") {
                    NavigationLink("Font-Rollen") { TypographyListView() }
                }
                Section("Motion") {
                    NavigationLink("Animations-Defaults") { MotionDemoView() }
                }
                Section("Shadow") {
                    NavigationLink("Shadow-Recipes") { ShadowDemoView() }
                }
                Section("Komponenten") {
                    NavigationLink("SectionHeader") { CatalogPage { SectionHeader(title: "STANDORT UND ZEIT") } }
                    NavigationLink("AppCard") {
                        CatalogPage {
                            AppCard {
                                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                    SectionHeader(title: "Notizen")
                                    Text("Käfer an Brennnessel, sonnig.")
                                        .font(AppFont.body)
                                }
                            }
                        }
                    }
                    NavigationLink("PrimaryButton") {
                        CatalogPage {
                            VStack(spacing: AppSpacing.md) {
                                PrimaryButton(title: "Probe anlegen", systemImage: "plus") {}
                                PrimaryButton(title: "Wird gespeichert …", isLoading: true) {}
                                PrimaryButton(title: "Deaktiviert", isEnabled: false) {}
                            }
                        }
                    }
                    NavigationLink("SyncStatusBadge") {
                        CatalogPage {
                            VStack(alignment: .leading, spacing: AppSpacing.md) {
                                HStack { SyncStatusBadge(status: .synced)
                                    Text("synced")
                                }
                                HStack { SyncStatusBadge(status: .pending)
                                    Text("pending")
                                }
                                HStack { SyncStatusBadge(status: .syncing)
                                    Text("syncing")
                                }
                                HStack { SyncStatusBadge(status: .failed)
                                    Text("failed")
                                }
                                Divider()
                                SyncStatusBadge(status: .synced, compact: false)
                                SyncStatusBadge(status: .pending, compact: false)
                                SyncStatusBadge(status: .syncing, compact: false)
                                SyncStatusBadge(status: .failed, compact: false)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Design-Katalog")
        }

        // MARK: - colour swatch data

        private var brandSwatches: [ColorSwatch] {
            [
                .init(name: "brandPrimary", color: AppColor.brandPrimary),
                .init(name: "brandPrimaryText", color: AppColor.brandPrimaryText),
                .init(name: "brandOnPrimary", color: AppColor.brandOnPrimary),
                .init(name: "brandPrimaryMuted", color: AppColor.brandPrimaryMuted)
            ]
        }

        private var surfaceSwatches: [ColorSwatch] {
            [
                .init(name: "surface", color: AppColor.surface),
                .init(name: "surfaceSecondary", color: AppColor.surfaceSecondary),
                .init(name: "surfaceTertiary", color: AppColor.surfaceTertiary),
                .init(name: "surfaceGrouped", color: AppColor.surfaceGrouped),
                .init(name: "separator", color: AppColor.separator),
                .init(name: "outlineSubtle", color: AppColor.outlineSubtle)
            ]
        }

        private var textSwatches: [ColorSwatch] {
            [
                .init(name: "textPrimary", color: AppColor.textPrimary),
                .init(name: "textSecondary", color: AppColor.textSecondary),
                .init(name: "textTertiary", color: AppColor.textTertiary)
            ]
        }

        private var statusSwatches: [ColorSwatch] {
            [
                .init(name: "success", color: AppColor.success),
                .init(name: "warning", color: AppColor.warning),
                .init(name: "danger", color: AppColor.danger),
                .init(name: "info", color: AppColor.info)
            ]
        }

        private var syncSwatches: [ColorSwatch] {
            [
                .init(name: "syncPending", color: AppColor.syncPending),
                .init(name: "syncInFlight", color: AppColor.syncInFlight),
                .init(name: "syncSynced", color: AppColor.syncSynced),
                .init(name: "syncFailed", color: AppColor.syncFailed)
            ]
        }
    }

    // MARK: - sub-views

    private struct ColorSwatch: Identifiable {
        let id = UUID()
        let name: String
        let color: Color
    }

    private struct ColorSwatchListView: View {
        let swatches: [ColorSwatch]

        var body: some View {
            List(swatches) { s in
                HStack(spacing: AppSpacing.md) {
                    RoundedRectangle(cornerRadius: AppRadius.sm)
                        .fill(s.color)
                        .frame(width: 56, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.sm)
                                .strokeBorder(AppColor.separator, lineWidth: 0.5)
                        )
                        .accessibilityHidden(true)
                    Text(s.name).font(AppFont.code)
                }
            }
        }
    }

    private struct SpacingScaleView: View {
        private let steps: [(String, CGFloat)] = [
            ("xxs", AppSpacing.xxs),
            ("xs", AppSpacing.xs),
            ("sm", AppSpacing.sm),
            ("md", AppSpacing.md),
            ("lg", AppSpacing.lg),
            ("xl", AppSpacing.xl),
            ("xxl", AppSpacing.xxl),
            ("xxxl", AppSpacing.xxxl)
        ]

        var body: some View {
            List(steps, id: \.0) { name, value in
                HStack(spacing: AppSpacing.md) {
                    Text(name).font(AppFont.code).frame(width: 48, alignment: .leading)
                    Rectangle()
                        .fill(AppColor.brandPrimary)
                        .frame(width: value, height: 20)
                        .accessibilityHidden(true)
                    Text("\(Int(value)) pt").font(AppFont.caption).foregroundStyle(AppColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(name), \(Int(value)) Punkt")
            }
        }
    }

    private struct RadiusScaleView: View {
        private let steps: [(String, CGFloat)] = [
            ("sm", AppRadius.sm),
            ("md", AppRadius.md),
            ("lg", AppRadius.lg),
            ("xl", AppRadius.xl),
            ("pill", AppRadius.pill)
        ]

        var body: some View {
            List(steps, id: \.0) { name, value in
                HStack(spacing: AppSpacing.md) {
                    Text(name).font(AppFont.code).frame(width: 48, alignment: .leading)
                    RoundedRectangle(cornerRadius: value)
                        .fill(AppColor.brandPrimary)
                        .frame(width: 80, height: 40)
                        .accessibilityHidden(true)
                    Text(value == AppRadius.pill ? "999 pt" : "\(Int(value)) pt")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
    }

    private struct TypographyListView: View {
        private struct Row: Identifiable {
            let id = UUID()
            let name: String
            let font: Font
        }

        private let rows: [Row] = [
            .init(name: "screenTitle", font: AppFont.screenTitle),
            .init(name: "sectionTitle", font: AppFont.sectionTitle),
            .init(name: "sectionHeading", font: AppFont.sectionHeading),
            .init(name: "headline", font: AppFont.headline),
            .init(name: "body", font: AppFont.body),
            .init(name: "bodyEmphasized", font: AppFont.bodyEmphasized),
            .init(name: "callout", font: AppFont.callout),
            .init(name: "subhead", font: AppFont.subhead),
            .init(name: "footnote", font: AppFont.footnote),
            .init(name: "caption", font: AppFont.caption),
            .init(name: "captionEmphasized", font: AppFont.captionEmphasized),
            .init(name: "code", font: AppFont.code),
            .init(name: "codeEmphasized", font: AppFont.codeEmphasized),
            .init(name: "codeLarge", font: AppFont.codeLarge)
        ]

        var body: some View {
            List(rows) { row in
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(row.name).font(AppFont.caption).foregroundStyle(AppColor.textSecondary)
                    Text("Aa Bb 260521/3").font(row.font)
                }
                .padding(.vertical, AppSpacing.xs)
            }
        }
    }

    private struct MotionDemoView: View {
        @State private var moved = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(spacing: AppSpacing.xl) {
                Text("Tippe um die Animation zu sehen — Reduce-Motion wird respektiert.")
                    .font(AppFont.callout)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, AppSpacing.lg)

                ForEach(motions, id: \.0) { name, anim in
                    HStack(spacing: AppSpacing.md) {
                        Text(name).font(AppFont.code).frame(width: 80, alignment: .leading)
                        Circle()
                            .fill(AppColor.brandPrimary)
                            .frame(width: 28, height: 28)
                            .offset(x: moved ? 120 : 0)
                            .animation(
                                AppMotion.respecting(anim, reduceMotion: reduceMotion),
                                value: moved
                            )
                        Spacer()
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }

                Button("Animieren") { moved.toggle() }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, AppSpacing.xl)
            .frame(maxWidth: .infinity)
        }

        private var motions: [(String, Animation)] {
            [("fast", AppMotion.fast), ("base", AppMotion.base), ("slow", AppMotion.slow), ("spring", AppMotion.spring)]
        }
    }

    private struct ShadowDemoView: View {
        var body: some View {
            VStack(spacing: AppSpacing.xl) {
                ForEach(items, id: \.0) { name, shadow in
                    VStack(spacing: AppSpacing.xs) {
                        Text(name).font(AppFont.caption).foregroundStyle(AppColor.textSecondary)
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .fill(AppColor.surface)
                            .frame(width: 220, height: 64)
                            .appShadow(shadow)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(AppColor.surfaceGrouped)
        }

        private var items: [(String, AppShadow)] {
            [("card", .card), ("elevated", .elevated)]
        }
    }

    /// Generic single-component preview page used by the components
    /// section. Renders the body once at default Dynamic Type and once
    /// at AX5 so drift is visible at a glance.
    private struct CatalogPage<Content: View>: View {
        let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    preview(label: "Default")
                    preview(label: "AX5").dynamicTypeSize(.accessibility5)
                }
                .padding()
            }
        }

        private func preview(label: String) -> some View {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(label).font(AppFont.caption).foregroundStyle(AppColor.textSecondary)
                content
            }
        }
    }

    #Preview("Catalog") {
        NavigationStack {
            DesignCatalogView()
        }
    }
#endif
