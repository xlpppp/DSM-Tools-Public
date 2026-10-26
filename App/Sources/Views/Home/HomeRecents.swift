import SwiftUI
import DSMKit

// MARK: Home cards

/// "相册 最近查看": a strip of recently opened photos. The eye button hides the thumbnails,
/// for showing the phone to someone without exposing private photos.
struct HomeRecentPhotosCard: View {
    let deviceID: UUID?

    @AppStorage("home.hideRecentPhotos") private var hidden = false
    @State private var viewer: PhotosView.ViewerState?

    private var recents: [RecentStore.RecentPhoto] { RecentStore.shared.photos(for: deviceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeCardTitle(symbol: Module.photos.symbol, color: Module.photos.color, title: "相册", subtitle: "最近查看") {
                RecentCardAccessories(hidden: $hidden, route: .recentPhotos)
            }
            if hidden {
                RecentHiddenNote()
            } else if recents.isEmpty {
                RecentEmptyNote(text: "暂无最近浏览的照片")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(recents.prefix(20)) { recent in
                            Button { open(recent) } label: {
                                RecentPhotoThumb(recent: recent).frame(width: 78, height: 78)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .card()
        .fullScreenCover(item: $viewer) { PhotoViewer(items: $0.items, start: $0.start, space: $0.space) }
    }

    private func open(_ recent: RecentStore.RecentPhoto) {
        viewer = RecentPhotosView.viewer(for: recent, in: recents)
    }
}

/// "文件 最近查看": the last few files opened from the file browser.
struct HomeRecentFilesCard: View {
    let deviceID: UUID?

    @AppStorage("home.hideRecentFiles") private var hidden = false
    @State private var preview: RemoteFile?

    private var recents: [RecentStore.RecentFile] { RecentStore.shared.files(for: deviceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeCardTitle(symbol: Module.files.symbol, color: Module.files.color, title: "文件", subtitle: "最近查看") {
                RecentCardAccessories(hidden: $hidden, route: .recentFiles)
            }
            if hidden {
                RecentHiddenNote()
            } else if recents.isEmpty {
                RecentEmptyNote(text: "暂无最近浏览的文件")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recents.prefix(4).enumerated()), id: \.element.id) { index, recent in
                        if index > 0 { Divider().padding(.leading, 50) }
                        Button { open(recent) } label: { RecentFileRow(recent: recent) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .card()
        .sheet(item: $preview) { FilePreviewView(file: $0) }
    }

    private func open(_ recent: RecentStore.RecentFile) {
        RecentStore.shared.record(recent.remote, device: deviceID)
        preview = recent.remote
    }
}

private struct RecentCardAccessories: View {
    @Binding var hidden: Bool
    let route: HomeRoute

    var body: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { hidden.toggle() }
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hidden ? "显示内容" : "隐藏内容")
            NavigationLink(value: route) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看全部")
        }
    }
}

private struct RecentHiddenNote: View {
    var body: some View {
        Label("内容已隐藏", systemImage: "eye.slash")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct RecentEmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct RecentPhotoThumb: View {
    let recent: RecentStore.RecentPhoto

    var body: some View {
        Color.clear
            .overlay { PhotoThumb(item: recent.item, space: recent.photoSpace, size: .small) }
            .background(Theme.subtle)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if recent.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
    }
}

private struct RecentFileRow: View {
    let recent: RecentStore.RecentFile

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(kind: FileKind.of(name: recent.name, isDirectory: false))
            VStack(alignment: .leading, spacing: 3) {
                Text(recent.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Text(RecentTime.string(recent.viewedAt)).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: Full lists

struct RecentPhotosView: View {
    @Environment(SessionManager.self) private var session
    @State private var viewer: PhotosView.ViewerState?
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmClear = false

    private var recents: [RecentStore.RecentPhoto] { RecentStore.shared.photos(for: session.deviceID) }

    static func viewer(for recent: RecentStore.RecentPhoto, in all: [RecentStore.RecentPhoto]) -> PhotosView.ViewerState {
        // The viewer pages within one photo space, so only that space's recents go in.
        let same = all.filter { $0.space == recent.space }
        let start = same.firstIndex(of: recent) ?? 0
        return PhotosView.ViewerState(items: same.map(\.item), start: start, space: recent.photoSpace)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 4)], spacing: 4) {
                ForEach(recents) { recent in
                    Button {
                        if selecting {
                            if selection.contains(recent.id) { selection.remove(recent.id) } else { selection.insert(recent.id) }
                        } else {
                            viewer = Self.viewer(for: recent, in: recents)
                        }
                    } label: {
                        RecentPhotoThumb(recent: recent)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .topTrailing) {
                                if selecting {
                                    Image(systemName: selection.contains(recent.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(.white, Theme.accent)
                                        .shadow(radius: 2)
                                        .padding(6)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .overlay {
            if recents.isEmpty {
                ContentUnavailableView("暂无最近浏览的照片", systemImage: "photo.on.rectangle")
            }
        }
        .background(Theme.background)
        .navigationTitle("相册 最近查看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            RecentListToolbar(selecting: $selecting, selectionCount: selection.count, isEmpty: recents.isEmpty,
                              onRemove: removeSelected, onClear: { confirmClear = true })
        }
        .confirmationDialog("清空最近查看的照片记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                RecentStore.shared.removePhotos(Set(recents.map(\.id)), device: session.deviceID)
            }
        } message: {
            Text("只删除本机的浏览记录，不会删除 NAS 上的照片。")
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(items: $0.items, start: $0.start, space: $0.space) }
    }

    private func removeSelected() {
        RecentStore.shared.removePhotos(selection, device: session.deviceID)
        selection.removeAll()
        selecting = false
    }
}

struct RecentFilesView: View {
    @Environment(SessionManager.self) private var session
    @State private var preview: RemoteFile?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var confirmClear = false

    private var recents: [RecentStore.RecentFile] { RecentStore.shared.files(for: session.deviceID) }

    var body: some View {
        List(selection: $selection) {
            ForEach(recents) { recent in
                Button {
                    RecentStore.shared.record(recent.remote, device: session.deviceID)
                    preview = recent.remote
                } label: {
                    RecentFileRow(recent: recent)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        RecentStore.shared.removeFiles([recent.path], device: session.deviceID)
                    } label: {
                        Label("移除", systemImage: "trash")
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .overlay {
            if recents.isEmpty {
                ContentUnavailableView("暂无最近浏览的文件", systemImage: "doc")
            }
        }
        .navigationTitle("文件 最近查看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            RecentListToolbar(selecting: Binding(get: { editMode == .active },
                                                 set: { editMode = $0 ? .active : .inactive }),
                              selectionCount: selection.count, isEmpty: recents.isEmpty,
                              onRemove: removeSelected, onClear: { confirmClear = true })
        }
        .confirmationDialog("清空最近查看的文件记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                RecentStore.shared.removeFiles(Set(recents.map(\.path)), device: session.deviceID)
            }
        } message: {
            Text("只删除本机的浏览记录，不会删除 NAS 上的文件。")
        }
        .sheet(item: $preview) { FilePreviewView(file: $0) }
    }

    private func removeSelected() {
        RecentStore.shared.removeFiles(selection, device: session.deviceID)
        selection.removeAll()
        editMode = .inactive
    }
}

private struct RecentListToolbar: ToolbarContent {
    @Binding var selecting: Bool
    let selectionCount: Int
    let isEmpty: Bool
    let onRemove: () -> Void
    let onClear: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "完成" : "选择") { selecting.toggle() }
                .disabled(isEmpty && !selecting)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if selecting {
                Button("清空全部", role: .destructive, action: onClear)
                Spacer()
                Button("移除 \(selectionCount) 项", role: .destructive, action: onRemove)
                    .disabled(selectionCount == 0)
            }
        }
    }
}
