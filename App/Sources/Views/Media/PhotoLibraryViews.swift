import SwiftUI
import PhotosUI
import DSMKit

// Synology Photos screens beyond the timeline: day-grouped grid, folders, people/places/tags,
// filtered item lists and uploading from the phone.

/// Thumbnails grouped by the day they were taken, newest first.
struct PhotoDayGrid: View {
    let items: [PhotoItem]
    let space: PhotoSpace
    let onOpen: (Int) -> Void
    let onReachEnd: () -> Void

    private struct Day: Identifiable {
        let id: String
        let title: String
        let indices: [Int]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        var order: [String] = []
        var titles: [String: String] = [:]
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            let key: String
            if let taken = item.taken {
                let start = calendar.startOfDay(for: taken)
                key = String(Int(start.timeIntervalSince1970))
                if titles[key] == nil { titles[key] = Self.title(for: start, calendar: calendar) }
            } else {
                key = "unknown"
                titles[key] = "未知日期"
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        return order.map { Day(id: $0, title: titles[$0] ?? "", indices: groups[$0] ?? []) }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日 EEEE"
        return f.string(from: day)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
            ForEach(days) { day in
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                        ForEach(day.indices, id: \.self) { index in
                            PhotoCell(item: items[index], space: space) { onOpen(index) }
                                .onAppear { if index == items.count - 1 { onReachEnd() } }
                        }
                    }
                } header: {
                    Text(day.title)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.background.opacity(0.94))
                }
            }
        }
    }
}

/// One square thumbnail with the video badge.
struct PhotoCell: View {
    let item: PhotoItem
    let space: PhotoSpace
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { PhotoThumb(item: item, space: space, size: .small) }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(5)
                            .shadow(radius: 2)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Items of one album, folder, person, place or tag, loaded page by page.
struct PhotoFilteredView: View {
    let title: String
    let space: PhotoSpace
    let filter: PhotoFilter

    @Environment(SessionManager.self) private var session
    @State private var items: [PhotoItem] = []
    @State private var loaded = false
    @State private var exhausted = false
    @State private var error: String?
    @State private var viewer: PhotosView.ViewerState?

    var body: some View {
        ScrollView {
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning).padding(.top, 8) }
            PhotoDayGrid(items: items, space: space) { index in
                viewer = PhotosView.ViewerState(items: items, start: index, space: space)
            } onReachEnd: {
                Task { await loadMore() }
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if items.isEmpty && error == nil {
                ContentUnavailableView("没有照片", systemImage: "photo")
            }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .fullScreenCover(item: $viewer) { PhotoViewer(items: $0.items, start: $0.start, space: $0.space) }
    }

    private func reload() async {
        guard let client = session.client else { return }
        do {
            items = try await client.photos(space: space, filter: filter, offset: 0, limit: 200)
            exhausted = items.count < 200
            error = nil
        } catch {
            self.error = error.userMessage
        }
        loaded = true
    }

    private func loadMore() async {
        guard let client = session.client, !exhausted else { return }
        exhausted = true
        if let more = try? await client.photos(space: space, filter: filter, offset: items.count, limit: 200) {
            items += more
            exhausted = more.count < 200
        }
    }
}

// MARK: Folders

/// Synology Photos' folder view: subfolders on top, the folder's own photos below.
struct PhotoFolderView: View {
    let space: PhotoSpace
    /// Nil opens the space's root folder.
    let folder: PhotoFolder?

    @Environment(SessionManager.self) private var session
    @State private var current: PhotoFolder?
    @State private var subfolders: [PhotoFolder] = []
    @State private var items: [PhotoItem] = []
    @State private var loaded = false
    @State private var exhausted = false
    @State private var unsupported = false
    @State private var error: String?
    @State private var viewer: PhotosView.ViewerState?

    /// True inside PhotosView's tab, which owns the title and toolbar.
    var embedded = false

    var body: some View {
        if embedded {
            content
                .task(id: space) { await reload() }
                .refreshable { await reload() }
                .fullScreenCover(item: $viewer) { PhotoViewer(items: $0.items, start: $0.start, space: $0.space) }
        } else {
            content
                .navigationTitle(current?.name ?? folder?.name ?? "文件夹")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let current {
                        ToolbarItem(placement: .topBarTrailing) {
                            PhotoUploadButton(space: space, folderPath: current.path) { await reload() }
                        }
                    }
                }
                .task(id: space) { await reload() }
                .refreshable { await reload() }
                .fullScreenCover(item: $viewer) { PhotoViewer(items: $0.items, start: $0.start, space: $0.space) }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if unsupported {
                ContentUnavailableView("不支持文件夹视图", systemImage: "folder",
                                       description: Text("此 NAS 的 Synology Photos 没有提供文件夹接口。"))
                    .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning).padding(.horizontal, 16) }
                    if !subfolders.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(subfolders) { sub in
                                NavigationLink {
                                    PhotoFolderView(space: space, folder: sub)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                                        Text(sub.name).foregroundStyle(.primary).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondaryText)
                                    }
                                    .padding(.vertical, 12)
                                }
                                if sub.id != subfolders.last?.id { Divider() }
                            }
                        }
                        .card(padding: 14)
                        .padding(.horizontal, 16)
                    }
                    if !items.isEmpty {
                        PhotoDayGrid(items: items, space: space) { index in
                            viewer = PhotosView.ViewerState(items: items, start: index, space: space)
                        } onReachEnd: {
                            Task { await loadMore() }
                        }
                    } else if loaded && subfolders.isEmpty && error == nil {
                        ContentUnavailableView("空文件夹", systemImage: "folder").padding(.top, 40)
                    }
                }
                .padding(.top, 8)
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .background(Theme.background)
    }

    private func reload() async {
        guard let client = session.client else { return }
        guard await client.supportsPhotoFolders(space) else {
            unsupported = true
            loaded = true
            return
        }
        unsupported = false
        do {
            let target: PhotoFolder
            if let folder {
                target = folder
            } else {
                target = try await client.photoFolder(space: space)
            }
            current = target
            subfolders = try await client.photoSubfolders(space: space, of: target.id)
            items = try await client.photos(space: space, filter: .folder(target.id), offset: 0, limit: 200)
            exhausted = items.count < 200
            error = nil
        } catch {
            self.error = error.userMessage
        }
        loaded = true
    }

    private func loadMore() async {
        guard let client = session.client, let current, !exhausted else { return }
        exhausted = true
        if let more = try? await client.photos(space: space, filter: .folder(current.id), offset: items.count, limit: 200) {
            items += more
            exhausted = more.count < 200
        }
    }
}

// MARK: People, places, tags

/// "发现" tab: a row per category with the first few covers and a link to all of them.
struct PhotoExploreView: View {
    let space: PhotoSpace

    @Environment(SessionManager.self) private var session
    @State private var groups: [PhotoCategory: [PhotoGroup]] = [:]
    @State private var available: [PhotoCategory] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if loaded && available.isEmpty {
                ContentUnavailableView("暂无可浏览的分类", systemImage: "sparkles",
                                       description: Text("此空间未开启人物识别、地点或标签，或 Synology Photos 版本不支持。"))
                    .padding(.top, 40)
            }
            ForEach(available, id: \.self) { category in
                section(category, list: groups[category] ?? [])
            }
        }
        .padding(.top, 4)
        .overlay { if !loaded { ProgressView().padding(.top, 60) } }
        .task(id: space) { await load() }
    }

    @ViewBuilder
    private func section(_ category: PhotoCategory, list: [PhotoGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(category.label).font(.headline)
                Spacer()
                if !list.isEmpty {
                    NavigationLink("全部 \(list.count)") { PhotoGroupListView(category: category, space: space, groups: list) }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 16)
            if list.isEmpty {
                Text("暂无\(category.label)").font(.footnote).foregroundStyle(Theme.secondaryText).padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(list.prefix(20)) { group in
                            NavigationLink {
                                PhotoFilteredView(title: group.displayName(category), space: space, filter: .group(category, group.id))
                            } label: {
                                PhotoGroupTile(group: group, category: category, space: space, side: 92)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        loaded = false
        var supported: [PhotoCategory] = []
        var result: [PhotoCategory: [PhotoGroup]] = [:]
        for category in PhotoCategory.allCases {
            guard await client.supportsPhotoCategory(category, space: space) else { continue }
            supported.append(category)
            result[category] = (try? await client.photoGroups(category, space: space)) ?? []
        }
        available = supported
        groups = result
        loaded = true
    }
}

struct PhotoGroupListView: View {
    let category: PhotoCategory
    let space: PhotoSpace
    let groups: [PhotoGroup]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 16) {
                ForEach(groups) { group in
                    NavigationLink {
                        PhotoFilteredView(title: group.displayName(category), space: space, filter: .group(category, group.id))
                    } label: {
                        PhotoGroupTile(group: group, category: category, space: space, side: 100)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(category.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension PhotoGroup {
    func displayName(_ category: PhotoCategory) -> String {
        name.isEmpty ? (category == .person ? "未命名" : "未知") : name
    }
}

/// Round avatar for people, rounded square for places and tags, with name and count.
struct PhotoGroupTile: View {
    let group: PhotoGroup
    let category: PhotoCategory
    let space: PhotoSpace
    let side: CGFloat

    @Environment(SessionManager.self) private var session
    @State private var url: URL?

    var body: some View {
        VStack(spacing: 6) {
            RemoteImage(url: url) {
                ZStack {
                    Theme.subtle
                    Image(systemName: icon).foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: side, height: side)
            .clipShape(category == .person ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
            Text(group.displayName(category)).font(.caption.weight(.medium)).lineLimit(1)
            Text("\(group.itemCount) 项").font(.caption2).foregroundStyle(Theme.secondaryText)
        }
        .frame(width: side)
        .task(id: group.id) {
            guard let client = session.client else { return }
            url = try? await client.photoGroupCoverURL(group, category: category, space: space)
        }
    }

    private var icon: String {
        switch category {
        case .person: return "person.fill"
        case .place: return "mappin.and.ellipse"
        case .tag: return "tag.fill"
        }
    }
}

// MARK: Upload

/// Picks photos and videos from the phone and uploads them into a Synology Photos folder.
/// Without a folder they go to "Upload" at the top of the space.
struct PhotoUploadButton: View {
    let space: PhotoSpace
    var folderPath: String?
    let onFinished: () async -> Void

    @Environment(SessionManager.self) private var session
    @State private var picked: [PhotosPickerItem] = []
    @State private var progress: String?
    @State private var result: String?

    var body: some View {
        PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
            if let progress {
                Label(progress, systemImage: "arrow.up.circle").labelStyle(.titleOnly).font(.caption)
            } else {
                Image(systemName: "arrow.up.circle")
            }
        }
        .disabled(progress != nil)
        .onChange(of: picked) { upload() }
        .alert("上传到 Synology Photos", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(result ?? "")
        }
    }

    private func upload() {
        let items = picked
        guard !items.isEmpty, let client = session.client else { return }
        picked = []
        Task {
            var done = 0
            var failed = 0
            var target = ""
            for (n, item) in items.enumerated() {
                progress = "\(n + 1)/\(items.count)"
                guard let file = try? await item.loadTransferable(type: PickedFile.self) else {
                    failed += 1
                    continue
                }
                do {
                    target = try await client.uploadPhoto(fileAt: file.url, space: space, folderPath: folderPath)
                    done += 1
                } catch {
                    failed += 1
                }
                try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
            }
            progress = nil
            var text = "已上传 \(done) 项"
            if !target.isEmpty { text += "到 \(target)" }
            text += "，Synology Photos 建立索引后显示。"
            if failed > 0 { text += "\n\(failed) 项失败（可能仍在 iCloud 中下载或网络中断）。" }
            result = text
            await onFinished()
        }
    }
}
