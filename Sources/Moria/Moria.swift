import AVKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main struct Moria: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        Window("Moria", id: "vault") { ContentView(vault: app.vault) }  // Sole Window scene: closing it quits, which locks.
            .defaultSize(width: 920, height: 580)
    }
}

/// Opens vaults double-clicked in Finder.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let vault = Vault()
    func application(_ application: NSApplication, open urls: [URL]) { vault.bundle = urls.first ?? vault.bundle }
}

extension ShapeStyle where Self == Color {
    /// The moonlit ink of the Doors of Durin: Apple's Spindrift crayon, the accent colour Assets.swift writes. Named
    /// rather than `.accentColor`, so the door keeps glowing Spindrift whatever accent the system is set to.
    static var ithildin: Color { Color("AccentColor") }
}

/// Primary actions glow in ithildin. Dark text, because white on Spindrift is unreadable.
struct Glowing: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(.ithildin.opacity(configuration.isPressed ? 0.7 : 1), in: .capsule)
            .shadow(color: .ithildin.opacity(enabled ? 0.5 : 0), radius: 10)
            .opacity(enabled ? 1 : 0.35)
    }
}

struct ContentView: View {
    @Bindable var vault: Vault
    @State private var showingCloud = false

    var body: some View {
        NavigationSplitView {
            Sidebar(vault: vault)
        } detail: {
            Group {
                if vault.store != nil { Browser(vault: vault) } else { LockScreen(vault: vault) }
            }
            .toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem { Button("Google Cloud", systemImage: vault.remote == nil ? "icloud" : "checkmark.icloud") { showingCloud = true } }
            }
        }
        .tint(.ithildin)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingCloud) { CloudSheet(vault: vault) }
        .task(id: vault.bundle) { await vault.unlockWithTouchID() }  // At launch, and whenever you pick a vault.
        .alert(vault.error ?? "", isPresented: Binding(isPresent: $vault.error)) {}
    }
}

/// Every vault opened here. Picking one locks the open one.
struct Sidebar: View {
    let vault: Vault

    var body: some View {
        List(selection: Binding(get: { vault.bundle?.path }, set: { $0.map { vault.bundle = URL(filePath: $0) } })) {
            Section("Vaults") {
                ForEach(vault.vaults, id: \.self) { path in
                    Label {
                        VStack(alignment: .leading) {
                            Text(URL(filePath: path).deletingPathExtension().lastPathComponent)
                            Text(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: vault.store != nil && path == vault.bundle?.path ? "lock.open.fill" : "lock.fill")
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                        Button("Remove from List") { vault.forget(path) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Button("New Vault…", systemImage: "plus") { vault.bundle = pickVault(NSSavePanel()) ?? vault.bundle }
                Button("Open Vault…", systemImage: "folder") { vault.bundle = pickVault(NSOpenPanel()) ?? vault.bundle }
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }
}

/// Asks where a vault is, or should go. Save panels suggest `name`.
@MainActor func pickVault(_ panel: NSSavePanel, name: String = "") -> URL? {
    panel.allowedContentTypes = [UTType(filenameExtension: "moria", conformingTo: .package)!]
    panel.nameFieldStringValue = name
    return panel.runModal() == .OK ? panel.url.map { URL(filePath: $0.path) } : nil
}

/// Asks where to export to, warning that exported copies aren't encrypted.
@MainActor func pickExportFolder() -> URL? {
    let panel = NSOpenPanel()
    (panel.canChooseDirectories, panel.canChooseFiles, panel.prompt) = (true, false, "Export")
    panel.message = "Exported copies aren't encrypted."
    return panel.runModal() == .OK ? panel.url : nil
}

/// The Doors of Durin, glowing in ithildin.
struct Door: View {
    var body: some View {
        Image(nsImage: NSImage(named: "Door") ?? NSImage())
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(.ithildin)
            .shadow(color: .ithildin, radius: 3)
            .shadow(color: .ithildin.opacity(0.7), radius: 18)
    }
}

struct LockScreen: View {
    let vault: Vault
    @AppStorage("touchID") private var touchID = true
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        VStack(spacing: 14) {
            Door().frame(height: 210).padding(.bottom, 18)
            if vault.bundle == nil {
                Text("Moria").font(.largeTitle.weight(.semibold))
                Text("Encrypted vaults for your files.").foregroundStyle(.secondary)
                HStack {
                    Button("New Vault…") { vault.bundle = pickVault(NSSavePanel()) }.buttonStyle(Glowing())
                    Button("Open Vault…") { vault.bundle = pickVault(NSOpenPanel()) }
                }
                .padding(.top, 8)
            } else {
                let creating = !vault.exists
                Text(vault.name).font(.largeTitle.weight(.semibold))
                if creating {
                    Text("Choose a password of 8 characters or more. Longer is safer, and with Touch ID you'll rarely type it. Nobody can recover it for you.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                else { BackupStatus(vault: vault) }
                SecureField(creating ? "Password" : "Speak, friend, and enter", text: $password).padding(.top, 8)
                if creating { SecureField("Confirm Password", text: $confirm) }
                Toggle("Remember with Touch ID", isOn: $touchID)
                HStack {
                    if !creating && vault.hasSavedSecret {
                        Button("Touch ID", systemImage: "touchid") { Task { await vault.unlockWithTouchID() } }
                    }
                    Button(creating ? "Create Vault" : "Unlock", action: submit)
                        .buttonStyle(Glowing())
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || creating && (password.count < 8 || password != confirm))
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .frame(width: 290)
        .disabled(vault.busy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RadialGradient(colors: [.ithildin.opacity(0.12), .black], center: .init(x: 0.5, y: 0.3), startRadius: 0, endRadius: 520))
        .navigationTitle(vault.name)
        .toolbar(removing: .title)
    }

    private func submit() {
        let (password, creating) = (password, !vault.exists)
        (self.password, confirm) = ("", "")
        Task {
            if creating { await vault.create(password: password, remember: touchID) }
            else { await vault.unlock(password, remember: touchID) }
        }
    }
}

struct Browser: View {
    let vault: Vault
    @State private var folder = ""  // The folder shown, as a path in the vault.
    @State private var selection = Set<String>()
    @State private var order = [KeyPathComparator(\Entry.name)]
    @State private var renaming: String?
    @State private var newName = ""
    @State private var doomed: Set<String>?
    @State private var viewing: Entry?
    @State private var targeted = false

    private var items: [Entry] { vault.children(of: folder).filter { !(folder.isEmpty && Browser.obsidian.contains($0.name)) }.sorted(using: order) }
    private static let obsidian: Set = [".obsidian", ".trash"]  // Obsidian's settings and deleted notes.
    /// While Obsidian edits the vault, Moria only views it, so their changes never cross.
    private var viewOnly: Bool { vault.obsidian != nil }

    var body: some View {
        let items = items
        Table(items, selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { entry in
                Label { Text(entry.name) } icon: { Image(nsImage: NSWorkspace.shared.icon(for: entry.type)).resizable().frame(width: 16, height: 16) }
            }
            TableColumn("Date Modified", value: \.date) { Text($0.date, format: .dateTime) }
            TableColumn("Size", value: \.size) { Text($0.isFolder ? "--" : $0.size.formatted(.byteCount(style: .file))) }
            TableColumn("Kind", value: \.kind)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            Button("Open") { open(paths) }
            Button("Export…") { if let folder = pickExportFolder() { vault.export(paths, to: folder) } }
            Button("Rename…") { rename(paths.first) }.disabled(paths.count != 1 || viewOnly)
            Button("Delete…") { doomed = paths }.disabled(viewOnly)
        } primaryAction: { open($0) }
        .onDeleteCommand { if !selection.isEmpty && !viewOnly { doomed = selection } }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label { Text("Drop files here") } icon: { Image(systemName: "tray.and.arrow.down").foregroundStyle(.ithildin) }
                } description: {
                    Text("They're encrypted as they land. Hold ⌘ to move them in, so no unencrypted copy is left behind.")
                }
            }
        }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).strokeBorder(.ithildin, lineWidth: 2).padding(6) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !viewOnly else { return false }
            vault.add(urls, to: folder, move: NSEvent.modifierFlags.contains(.command))
            return true
        } isTargeted: { targeted = $0 && !viewOnly }
        .safeAreaInset(edge: .top, spacing: 0) {
            if viewOnly {
                HStack {
                    Label("Open in Obsidian. Until you close it, any app on this Mac can read these files.", systemImage: "lock.open.trianglebadge.exclamationmark")
                    Spacer()
                    Button("Close Obsidian", action: vault.closeObsidian)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ithildin.opacity(0.15))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                BackupStatus(vault: vault)
                Spacer()
                Text("^[\(items.count) item](inflect: true), \(items.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle(vault.name)
        .navigationSubtitle(folder.split(separator: "/").joined(separator: " › "))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { folder = (folder as NSString).deletingLastPathComponent }
                    .keyboardShortcut(.upArrow).disabled(folder.isEmpty)
            }
            ToolbarItemGroup {
                if vault.working > 0 { ProgressView().controlSize(.small) }
                Button("New Folder", systemImage: "folder.badge.plus") { rename(vault.newFolder(in: folder)) }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(viewOnly)
                if let obsidian = Obsidian.app {
                    Button { Task { await vault.openInObsidian() } } label: {
                        Label { Text("Open in Obsidian") } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: obsidian.path)).resizable().frame(width: 20, height: 20) }
                    }
                    .help("Open this vault in Obsidian. Until Obsidian closes, any app on this Mac can read its files.")
                }
                Button("Lock", systemImage: "lock", action: vault.lock).keyboardShortcut("l")
            }
        }
        .onChange(of: folder) { selection = [] }
        .sheet(item: $viewing) { Viewer(vault: vault, entry: $0) }
        .alert("Rename", isPresented: Binding(isPresent: $renaming), presenting: renaming) { path in
            TextField("Name", text: $newName)
            Button("Rename") { vault.rename(path, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Permanently delete \(doomed?.count ?? 0) item(s)?", isPresented: Binding(isPresent: $doomed), presenting: doomed) { paths in
            Button("Delete", role: .destructive) { vault.delete(paths) }
        }
    }

    private func open(_ paths: Set<String>) {
        guard let entry = paths.first.flatMap({ vault.entries[$0] }) else { return }
        if entry.isFolder { folder = entry.path } else { viewing = entry }
    }

    private func rename(_ path: String?) { (newName, renaming) = (path.map { ($0 as NSString).lastPathComponent } ?? "", path) }
}

/// Shows a file straight from memory, so it's never written anywhere unencrypted.
struct Viewer: View {
    let vault: Vault
    let entry: Entry
    @Environment(\.dismiss) private var dismiss
    @State private var shown: Shown?

    /// What a file shows as, built once from its decrypted bytes.
    enum Shown {
        case pdf(PDFDocument), image(NSImage), media(MemoryMedia), text(NSAttributedString, paper: Bool), message(String, String)
    }

    /// Documents AppKit's text system reads, with their formatting.
    private static let documents: [String: NSAttributedString.DocumentType] = [
        UTType.rtf.identifier: .rtf, "com.microsoft.word.doc": .docFormat,
        "org.openxmlformats.wordprocessingml.document": .officeOpenXML, "org.oasis-open.opendocument.text": .openDocument,
    ]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch shown {
                case .pdf(let document): PDFReader(document: document)
                case .image(let image): Image(nsImage: image).resizable().scaledToFit().padding()
                case .media(let media): MediaPlayer(player: media.player)
                case .text(let text, let paper): TextReader(text: text, paper: paper)
                case .message(let title, let detail): ContentUnavailableView(title, systemImage: "eye.slash", description: Text(detail))
                case nil: ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Label { Text(entry.name).fontWeight(.semibold) } icon: { Image(nsImage: NSWorkspace.shared.icon(for: entry.type)) }
                Spacer()
                Button("Export…") { if let folder = pickExportFolder() { vault.export([entry.path], to: folder) } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(minWidth: 760, minHeight: 540)
        .task { shown = await show() }
    }

    private func show() async -> Shown {
        let type = entry.type, document = Viewer.documents[type.identifier]
        guard document != nil || [.pdf, .image, .audiovisualContent, .text].contains(where: type.conforms) else {
            return .message("Moria can't show this kind of file yet", "Export it to open it in another app. The exported copy isn't encrypted.")
        }
        do {
            let data = try await vault.contents(of: entry)
            if type.conforms(to: .pdf), let pdf = PDFDocument(data: data) { return .pdf(pdf) }
            if type.conforms(to: .image), let image = NSImage(data: data) { return .image(image) }
            if type.conforms(to: .audiovisualContent) { return .media(MemoryMedia(data, type: type)) }
            if let document, let text = try? NSAttributedString(data: data, options: [.documentType: document], documentAttributes: nil) {
                return .text(text, paper: true)
            }
            if let text = String(data: data, encoding: .utf8) {
                return .text(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                                           .foregroundColor: NSColor.textColor]), paper: false)
            }
            return .message("Moria couldn't read “\(entry.name)”", "It may be damaged. Try exporting it.")
        } catch {
            return .message("Couldn't decrypt “\(entry.name)”", error.localizedDescription)
        }
    }
}

struct PDFReader: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        (view.autoScales, view.document) = (true, document)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

/// Read-only, selectable text: plain, or a document's own formatting on white paper.
struct TextReader: NSViewRepresentable {
    let text: NSAttributedString
    let paper: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        (view.isEditable, view.textContainerInset) = (false, NSSize(width: 24, height: 20))
        if paper { view.appearance = NSAppearance(named: .aqua) }  // Documents expect black ink on white.
        view.textStorage?.setAttributedString(text)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

struct MediaPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

/// Plays audio or video from memory, handing AVFoundation the decrypted bytes through a URL only this player knows.
final class MemoryMedia: NSObject, AVAssetResourceLoaderDelegate {
    private let data: Data, type: UTType
    private(set) var player = AVPlayer()

    init(_ data: Data, type: UTType) {
        (self.data, self.type) = (data, type)
        super.init()
        let asset = AVURLAsset(url: URL(string: "moria://media")!)
        asset.resourceLoader.setDelegate(self, queue: .main)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            (info.contentType, info.contentLength, info.isByteRangeAccessSupported) = (type.identifier, Int64(data.count), true)
        }
        if let wanted = request.dataRequest {
            let start = Int(wanted.requestedOffset)
            let end = wanted.requestsAllDataToEndOfResource ? data.count : min(data.count, start + wanted.requestedLength)
            wanted.respond(with: data.subdata(in: start..<end))
        }
        request.finishLoading()
        return true
    }
}

extension Binding where Value == Bool {
    init<T: Sendable>(isPresent value: Binding<T?>) {
        self.init(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
