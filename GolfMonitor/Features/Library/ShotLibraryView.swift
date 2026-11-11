import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Swings tab: every saved shot, newest first, grouped by day — thumbnail,
/// the headline numbers, swipe to favourite / delete, tap to open the Swing
/// Studio. A filter bar narrows it to one club and the summary strip shows
/// that club's averages and best.
struct ShotLibraryView: View {
    @EnvironmentObject private var store: ShotStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @State private var club: Club?
    @State private var compare: Shot?
    @State private var export: URL?
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingImport: ImportedSwingVideo?
    @State private var importError: String?

    private var shots: [Shot] { store.shots(for: club) }

    private var days: [(day: Date, shots: [Shot])] {
        let grouped = Dictionary(grouping: shots) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.map { ($0.key, $0.value.sorted { $0.date > $1.date }) }.sorted { $0.day > $1.day }
    }

    private var clubsInLibrary: [Club] {
        Club.allCases.filter { c in store.shots.contains { $0.club == c } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.shots.isEmpty {
                    EmptyStateView(icon: "figure.golf", title: "No swings yet",
                                   message: "Record on the Range or import a video from Photos or Files to add swings here.",
                                   actionTitle: "Go to the Range") { router.tab = .range }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(FloodlightBackground(animated: false))
            .navigationTitle("Swings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import from Photos", systemImage: "photo") { showPhotosPicker = true }
                        Button("Import from Files", systemImage: "folder") { showFileImporter = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import swing video")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GolfMonitor-shots.csv")
                        try? store.csvString().write(to: url, atomically: true, encoding: .utf8)
                        export = url
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(store.shots.isEmpty)
                    .accessibilityLabel("Export shots as CSV")
                }
            }
            .sheet(item: $compare) { ProCompareView(shot: $0) }
            .sheet(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } })) {
                if let export { ShareSheet(items: [export]) }
            }
            .sheet(item: $pendingImport) { video in
                SwingImportSheet(videoURL: video.url)
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $photoItem, matching: .videos)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let video = try await item.loadTransferable(type: ImportedSwingVideo.self) else {
                            throw SwingImportError.noVideo
                        }
                        pendingImport = video
                    } catch {
                        importError = error.localizedDescription
                    }
                    photoItem = nil
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
                do {
                    guard let source = try result.get().first else { throw SwingImportError.noVideo }
                    let hasAccess = source.startAccessingSecurityScopedResource()
                    defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("golfmonitor-import-\(UUID().uuidString).\(source.pathExtension)")
                    try FileManager.default.copyItem(at: source, to: destination)
                    pendingImport = ImportedSwingVideo(url: destination)
                } catch {
                    importError = error.localizedDescription
                }
            }
            .alert("Unable to Import Video", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "Please choose a video and try again.")
            }
        }
    }

    private var list: some View {
        List {
            Section {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                summary
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)

            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.shots) { shot in
                        ShotRow(shot: shot)
                            .contentShape(Rectangle())
                            .onTapGesture { open(shot) }
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.delete(ids: [shot.id]) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button { store.toggleFavorite(shot.id) } label: {
                                    Label(shot.isFavorite ? "Unfavourite" : "Favourite", systemImage: "star.fill")
                                }
                                .tint(Theme.Palette.caution)
                            }
                            .contextMenu {
                                if shot.hasMedia {
                                    Button("Open in Swing Studio", systemImage: "play.rectangle") { router.openStudio(shot.id) }
                                }
                                if shot.hasLaunchData {
                                    Button("Compare with tour", systemImage: "chart.bar.xaxis") { compare = shot }
                                }
                                Button(shot.isFavorite ? "Unfavourite" : "Favourite", systemImage: "star") {
                                    store.toggleFavorite(shot.id)
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(ids: [shot.id]) }
                            }
                    }
                } header: {
                    Text(day.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(Theme.Font.label)
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Palette.mist)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(Theme.Motion.snappy, value: club)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All", isSelected: club == nil, color: Theme.Palette.plasma) { club = nil }
                ForEach(clubsInLibrary) { c in
                    Chip(title: c.shortName, isSelected: club == c, color: Theme.color(for: c)) {
                        club = club == c ? nil : c
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var summary: some View {
        let measured = shots.filter(\.hasLaunchData)
        let carries = measured.map(\.carryYards)
        let tempos = shots.map(\.tempoRatio).filter { $0 > 0 }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        return HStack(spacing: 10) {
            stat("Shots", Double(shots.count), "", 0)
            stat("Avg carry", mean(carries).map { settings.distanceValue(yards: $0) }, settings.distanceUnitLabel, 0)
            stat("Best", carries.max().map { settings.distanceValue(yards: $0) }, settings.distanceUnitLabel, 0,
                 highlight: Theme.Palette.apexViolet)
            stat("Tempo", mean(tempos), ":1", 1)
        }
    }

    private func stat(_ label: String, _ value: Double?, _ unit: String, _ digits: Int, highlight: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CapsLabel(label, color: highlight ?? Theme.Palette.mist)
            NumberText(value: value, digits: digits, unit: unit, font: Theme.Font.metric(24))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: Theme.Radius.s)
    }

    private func open(_ shot: Shot) {
        if shot.hasMedia {
            router.openStudio(shot.id)
        } else if shot.hasLaunchData {
            compare = shot
        }
    }
}

private struct ShotRow: View {
    let shot: Shot
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            ShotThumbnail(shot: shot)
                .frame(width: 58, height: 76)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(shot.club.shortName)
                        .font(.system(size: 12, weight: .black).width(.condensed))
                        .foregroundStyle(Theme.Palette.void)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.color(for: shot.club), in: Capsule())
                    Text(shot.date.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Palette.mist)
                    if shot.source == .demo { badge("DEMO") }
                    if shot.source == .imported { badge("IMPORTED") }
                    if shot.cameraView == .downTheLine { badge("DTL") }
                    Spacer(minLength: 0)
                    if shot.isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.Palette.caution)
                    }
                }
                if shot.hasLaunchData {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        NumberText(value: settings.distanceValue(yards: shot.carryYards), unit: settings.distanceUnitLabel,
                                   font: Theme.Font.metric(30), prefix: "~")
                        Text("\(Int(settings.speedValue(mph: shot.ballSpeedMph).rounded())) \(settings.speedUnitLabel) · \(String(format: "%.1f°", shot.launchAngleDeg))")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.mist)
                            .lineLimit(1)
                    }
                } else {
                    Text(shot.tempoRatio > 0 ? "Swing · tempo \(String(format: "%.1f", shot.tempoRatio)):1" : "Swing analysis")
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.Palette.floodlight)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(Theme.Palette.dim)
        }
        .padding(10)
        .contentCard(cornerRadius: Theme.Radius.m)
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy).width(.expanded))
            .foregroundStyle(Theme.Palette.mist)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Theme.Palette.hairlineStrong, lineWidth: 1))
    }
}

/// Poster frame, loaded off the main thread.
private struct ShotThumbnail: View {
    let shot: Shot
    @EnvironmentObject private var store: ShotStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.Palette.graphite
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: shot.hasMedia ? "film" : "chart.bar.fill")
                    .foregroundStyle(Theme.Palette.dim)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: shot.id) {
            guard shot.hasMedia, let url = store.thumbnailURL(for: shot.id) else { return }
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
        }
    }
}
