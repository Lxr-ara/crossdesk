import SwiftUI
import UIKit

/// One photo advertised by the host through the shared `file_browser` RPC
/// (`op: "gallery"`). Paths are absolute UTF-8 strings on the host side.
struct PhotoEntry: Identifiable, Equatable {
    let path: String
    let name: String
    let album: String
    let size: Int64
    let modified: String

    var id: String { path }
}

/// Controller-side album for iOS. Reuses the desktop contract:
///   op "gallery" -> paginated photo listing (path/album/modified/size)
///   op "thumb"   -> base64 JPEG thumbnail for one path
///   op "copy"    -> ask the host to stream the originals; the host then sends
///                   us `op: "prepare"`, which we acknowledge, and the bytes
///                   arrive through the existing file-transfer session into
///                   Documents/Received.
final class PhotoGalleryStore: ObservableObject {
    @Published private(set) var entries: [PhotoEntry] = []
    @Published private(set) var albums: [String] = []
    @Published var album = ""
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var status = ""
    @Published private(set) var errorText = ""
    @Published private(set) var busy = false
    @Published private(set) var receivedFiles = 0

    /// Filled by RemoteSessionModel with the bridge transport.
    var sendMessage: ((Data) -> Void)?

    private struct GalleryRequest {
        let path: String
        var entries: [PhotoEntry]
    }

    private var nextID = 1
    private var galleryRequests: [Int: GalleryRequest] = [:]
    private var thumbnailRequests: [Int: String] = [:]
    private var downloading = false

    // MARK: - Requests

    func refresh(path: String = "@photos") {
        guard let sendMessage else { return }
        busy = true
        errorText = ""
        status = "正在读取照片…"
        let id = allocateID()
        galleryRequests[id] = GalleryRequest(path: path, entries: [])
        send(sendMessage, ["type": "file_browser", "version": 1, "op": "gallery",
                           "id": id, "path": path, "recursive": 1, "pagination": 1])
    }

    func loadThumbnail(for entry: PhotoEntry, edge: Int = 192) {
        guard let sendMessage, thumbnails[entry.path] == nil else { return }
        let id = allocateID()
        thumbnailRequests[id] = entry.path
        send(sendMessage, ["type": "file_browser", "version": 1, "op": "thumb",
                           "id": id, "path": entry.path, "edge": edge])
    }

    func downloadSelected() {
        guard let sendMessage, !selected.isEmpty, !downloading else { return }
        let paths = Array(selected)
        let transferID = UUID().uuidString
        downloading = true
        receivedFiles = 0
        status = "已请求远端发送 \(paths.count) 张，正在接收…"
        // The receiver always writes into Documents/Received, so the destination
        // string is informational for the host's reservation reply.
        send(sendMessage, ["type": "file_browser", "version": 1, "op": "copy",
                           "id": allocateID(), "paths": paths,
                           "destination": "Received", "transfer_id": transferID])
    }

    // MARK: - Incoming messages

    func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1 else { return }
        switch object["op"] as? String {
        case "reply": handleReply(object)
        case "prepare": answerPrepare(object)
        case "notice":
            if let ok = object["ok"] as? Bool, ok == false {
                let reason = (object["error"] as? String) ?? "unknown"
                errorText = "远端发送失败：\(reason)"
            }
            downloading = false
        default:
            break
        }
    }

    private func handleReply(_ object: [String: Any]) {
        guard let id = object["id"] as? Int else { return }
        if let path = thumbnailRequests.removeValue(forKey: id) {
            if object["ok"] as? Bool == true, let base64 = object["data"] as? String,
               let image = PhotoGalleryStore.decodeImage(base64) {
                thumbnails[path] = image
            }
            return
        }
        guard var request = galleryRequests[id] else { return }
        if object["ok"] as? Bool == false {
            galleryRequests[id] = nil
            busy = false
            errorText = "无法读取照片列表：\((object["error"] as? String) ?? "unknown")"
            return
        }
        for item in (object["entries"] as? [[String: Any]]) ?? [] {
            guard let path = item["path"] as? String, let name = item["name"] as? String else { continue }
            request.entries.append(PhotoEntry(path: path,
                                              name: name,
                                              album: (item["album"] as? String) ?? "",
                                              size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                                              modified: (item["modified"] as? String) ?? ""))
        }
        if let next = object["next"] as? String, !next.isEmpty {
            galleryRequests[id] = request
            status = "已读取 \(request.entries.count) 张…"
            guard let sendMessage else { return }
            send(sendMessage, ["type": "file_browser", "version": 1, "op": "gallery",
                               "id": id, "path": request.path, "recursive": 1,
                               "pagination": 1, "cursor": next])
            return
        }
        galleryRequests[id] = nil
        entries = request.entries
        albums = Array(Set(entries.map { $0.album.isEmpty ? "未分组" : $0.album })).sorted()
        if !album.isEmpty && !albums.contains(album) { album = "" }
        selected = selected.filter { path in entries.contains { $0.path == path } }
        busy = false
        errorText = ""
        status = "\(entries.count) 张照片"
    }

    /// The host reserves destinations through `op: "prepare"` before it streams
    /// the originals. The iOS receiver always writes into Documents/Received, so
    /// acknowledging is enough.
    private func answerPrepare(_ object: [String: Any]) {
        guard let sendMessage, let id = object["id"] as? Int else { return }
        var reply: [String: Any] = ["type": "file_browser", "version": 1,
                                    "op": "reply", "id": id, "ok": true]
        if let transferID = object["transfer_id"] as? String { reply["transfer_id"] = transferID }
        send(sendMessage, reply)
    }

    func handleReceivedFile(_ url: URL) {
        guard downloading else { return }
        receivedFiles += 1
        status = "已接收 \(receivedFiles) 张，保存在「文件」App 的 CrossDesk/Received"
    }

    // MARK: - Selection

    func toggle(_ entry: PhotoEntry) {
        if selected.contains(entry.path) { selected.remove(entry.path) }
        else { selected.insert(entry.path) }
    }

    func selectAll() { selected = Set(visibleEntries.map { $0.path }) }
    func clearSelection() { selected.removeAll() }

    var visibleEntries: [PhotoEntry] {
        guard !album.isEmpty else { return entries }
        return entries.filter { ($0.album.isEmpty ? "未分组" : $0.album) == album }
    }

    // MARK: - Helpers

    private func allocateID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func send(_ transport: (Data) -> Void, _ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        transport(data)
    }

    private static func decodeImage(_ base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }
}

struct PhotoGalleryView: View {
    @ObservedObject var store: PhotoGalleryStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]
    private let accent = Color(red: 0.21, green: 0.39, blue: 0.89)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                albumBar
                Divider()
                grid
                Divider()
                statusBar
            }
            .navigationTitle("照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("刷新") { store.refresh() }
                    Button("全选") { store.selectAll() }
                    Button("清空") { store.clearSelection() }
                        .disabled(store.selected.isEmpty)
                    Spacer()
                    Button("保存到本机") { store.downloadSelected() }
                        .disabled(store.selected.isEmpty)
                }
            }
            .task { if store.entries.isEmpty { store.refresh() } }
        }
    }

    private var albumBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部照片", active: store.album.isEmpty) { store.album = "" }
                ForEach(store.albums, id: \.self) { album in
                    chip(album, active: store.album == album) { store.album = album }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? accent : Color.secondary.opacity(0.12))
                .foregroundStyle(active ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.visibleEntries) { entry in
                    tile(entry)
                }
            }
            .padding(8)
        }
        .overlay {
            if store.busy && store.entries.isEmpty {
                ProgressView("正在读取照片…")
            } else if store.entries.isEmpty && !store.errorText.isEmpty {
                Text(store.errorText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private func tile(_ entry: PhotoEntry) -> some View {
        let isSelected = store.selected.contains(entry.path)
        return Button {
            store.toggle(entry)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                    if let image = store.thumbnails[entry.path] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(entry.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(4)
                            .task { store.loadThumbnail(for: entry) }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 2)
                )
                Text(entry.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private var statusBar: some View {
        HStack {
            Text(store.errorText.isEmpty ? store.status : store.errorText)
                .font(.footnote)
                .foregroundStyle(store.errorText.isEmpty ? Color.secondary : Color.red)
                .lineLimit(1)
            Spacer()
            if !store.selected.isEmpty {
                Text("已选 \(store.selected.count) 张")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
