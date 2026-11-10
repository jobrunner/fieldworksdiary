import SwiftUI

/// Root dashboard the user lands on after sign-in. Replaces the
/// previous 5-tab bar.
///
/// „Sample anlegen“ creates the sample instantly (Phase E) and pushes
/// its editor onto the stack. „Probe nachtragen“ opens the unsaved
/// create path in „Nachträglich“ mode (coordinate from the map, saved
/// with „Probe anlegen“). Other destinations push via `NavigationLink`
/// and reuse the existing list screens.
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
            placemarks: container.placemarksStore,
            sync: container.sync,
            creator: InstantSampleCreator(
                store: container.store,
                localitiesStore: container.localitiesStore,
                mutationsStore: container.mutations,
                sync: container.sync,
                pendingFixes: container.pendingFixes,
                locationResolver: container.makeLocationResolver(),
                currentFix: { LocationProvider.recentFix() }
            )
        )
    }
}

private struct HomeContent: View {
    @StateObject private var viewModel: HomeViewModel

    private let sync: SyncRunner

    /// Divider inset that lines up with the row titles: row padding +
    /// icon + icon spacing; grows with the icon under Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var dividerInset: CGFloat =
        AppSpacing.lg + HomeMenuRow.baseIconSize + AppSpacing.lg

    init(
        auth: AuthSession,
        samples: LocalSampleStore,
        fieldtrips: LocalFieldtripStore,
        localities: LocalLocalityStore,
        photos: LocalPhotoStore,
        placemarks: LocalPlacemarkStore,
        sync: SyncRunner,
        creator: InstantSampleCreator
    ) {
        _viewModel = StateObject(wrappedValue: HomeViewModel(
            auth: auth,
            samples: samples,
            fieldtrips: fieldtrips,
            localities: localities,
            photos: photos,
            placemarks: placemarks,
            creator: creator
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
                        onAddSample: { viewModel.createSample() }
                    )
                    menuList
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .task { viewModel.refresh() }
            .onChange(of: sync.inFlight) { _, _ in viewModel.refresh() }
            .onChange(of: viewModel.newSample) { _, created in
                // Refresh once the editor is popped — covers both a
                // saved and a deleted (empty id) new sample.
                if created == nil { viewModel.refresh() }
            }
            .navigationDestination(item: $viewModel.newSample) { created in
                SampleEditorView(
                    sampleID: created.id,
                    isNew: true,
                    suggestedRunning: created.suggestedRunning
                )
            }
            .alert(
                "Fehler",
                isPresented: Binding(
                    get: { viewModel.createError != nil },
                    set: { if !$0 { viewModel.createError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.createError ?? "")
            }
        }
    }

    private var menuList: some View {
        VStack(spacing: 0) {
            row(icon: "arrow.up.right.square",
                title: "Letzte Probe",
                destination: { recentSampleDestination }) // last sample shortcut

            row(icon: "clock.arrow.circlepath",
                title: "Probe nachtragen",
                destination: { SampleEditorView(sampleID: nil, initialMode: .later) })

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
                        hydrator: container.hydrator,
                        samples: container.store,
                        placemarks: container.placemarksStore
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
        .padding(.top, AppSpacing.sm)
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
                .padding(.horizontal, AppSpacing.lg)
        }
        .buttonStyle(.plain)
        Divider()
            .padding(.leading, dividerInset)
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
