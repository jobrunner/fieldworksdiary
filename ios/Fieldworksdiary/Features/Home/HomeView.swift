import SwiftUI

/// Root dashboard the user lands on after sign-in. Replaces the
/// previous 5-tab bar.
///
/// The new sample flow opens as a sheet so the dashboard's at-a-glance
/// context stays visible behind it. Other destinations push onto the
/// stack via `NavigationLink` and reuse the existing list screens.
struct HomeView: View {
    @EnvironmentObject var container: AppContainer
    @EnvironmentObject var auth: AuthSession

    var body: some View {
        HomeContent(
            auth: auth,
            samples: container.store,
            fieldtrips: container.fieldtrips,
            localities: container.localitiesStore,
            photos: container.photos,
            sync: container.sync
        )
    }
}

private struct HomeContent: View {
    @StateObject private var viewModel: HomeViewModel
    @State private var presentingNewSample = false

    private let sync: SyncRunner

    init(
        auth: AuthSession,
        samples: LocalSampleStore,
        fieldtrips: LocalFieldtripStore,
        localities: LocalLocalityStore,
        photos: LocalPhotoStore,
        sync: SyncRunner
    ) {
        _viewModel = StateObject(wrappedValue: HomeViewModel(
            auth: auth,
            samples: samples,
            fieldtrips: fieldtrips,
            localities: localities,
            photos: photos
        ))
        self.sync = sync
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    HomeHeader(
                        collectorName: viewModel.collectorName,
                        activeFieldtrip: viewModel.activeFieldtrip,
                        recentSample: viewModel.recentSample,
                        onAddSample: { presentingNewSample = true }
                    )
                    menuList
                }
            }
            .background(Color(.systemGroupedBackground))
            // `.navigationBarHidden(_:)` ist seit iOS 16 deprecated.
            // Auf iOS 26 (Liquid Glass) erzeugt der dynamische
            // NavBar-Wechsel beim Push (Home: hidden → Detail: shown)
            // ein Re-Layout, das das beobachtete „kurz korrekt, dann
            // clippt" auf Detail-Views auslösen kann. Die moderne
            // `.toolbar(.hidden, …)`-API verhält sich vorhersagbarer.
            .toolbar(.hidden, for: .navigationBar)
            .task { viewModel.refresh() }
            .onChange(of: sync.inFlight) { _, _ in viewModel.refresh() }
            .onChange(of: presentingNewSample) { _, isPresented in
                // Refresh once the sheet closes — covers both "user
                // submitted a sample" and "user cancelled" without
                // needing a callback closure.
                if !isPresented { viewModel.refresh() }
            }
            .sheet(isPresented: $presentingNewSample) {
                AddSampleSheet()
            }
        }
    }

    private var menuList: some View {
        VStack(spacing: 0) {
            row(icon: "arrow.up.right.square",
                title: "Letzte Probe",
                destination: { recentSampleDestination }) // last sample shortcut

            row(icon: "photo.on.rectangle.angled",
                title: "Proben",
                count: viewModel.sampleCount,
                destination: { SamplesListScreen() })

            row(icon: "star",
                title: "Markierte Proben",
                count: viewModel.markedCount,
                destination: { MarkedSamplesScreen() })

            row(icon: "calendar.badge.clock",
                title: "Exkursionen",
                count: viewModel.fieldtripCount,
                destination: {
                    FieldtripsListScreen(
                        store: container.fieldtrips,
                        hydrator: container.hydrator
                    )
                })

            row(icon: "mappin.and.ellipse",
                title: "Fundorte",
                count: viewModel.localityCount,
                destination: {
                    LocalitiesListScreen(
                        store: container.localitiesStore,
                        hydrator: container.localitiesHydrator
                    )
                })

            row(icon: "photo.stack",
                title: "Fotos",
                count: viewModel.photoCount,
                destination: { PhotosGalleryScreen() })

            row(icon: "calendar",
                title: "Kalender",
                destination: { CalendarScreen() })

            row(icon: "heart.text.square",
                title: "Status",
                destination: { HealthScreen() })

            row(icon: "gearshape",
                title: "Einstellungen",
                destination: { SettingsScreen() })
        }
        .padding(.top, 8)
    }

    @EnvironmentObject private var container: AppContainer

    @ViewBuilder
    private func row<Dest: View>(
        icon: String,
        title: String,
        count: Int? = nil,
        @ViewBuilder destination: @escaping () -> Dest
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HomeMenuRow(title: title, systemImage: icon, count: count)
                .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        Divider()
            .padding(.leading, 60)
    }

    /// Recent-sample row jumps either to the sample's detail (when
    /// there is one) or to the empty samples list.
    @ViewBuilder
    private var recentSampleDestination: some View {
        if let recent = viewModel.recentSample {
            SampleEditorView(sampleID: recent.id)
        } else {
            SamplesListScreen()
        }
    }
}

/// The "+" sheet is its own struct so it can read the container from
/// the environment without the parent having to re-inject it. Phase
/// 14c replaced the old AddSampleView with the two-section
/// `SampleEditorView`.
private struct AddSampleSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SampleEditorView(sampleID: nil)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Schließen") { dismiss() }
                    }
                }
        }
    }
}
