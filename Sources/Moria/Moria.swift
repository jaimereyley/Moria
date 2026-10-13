import SwiftUI
import UniformTypeIdentifiers

@main struct Moria: App {
    @State private var vault = Vault()

    var body: some Scene {
        Window("Moria", id: "vault") { ContentView(vault: vault) }  // Sole Window scene: closing it quits, which locks.
            .defaultSize(width: 920, height: 580)
    }
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
                if let mount = vault.mount { Browser(vault: vault, root: mount) } else { LockScreen(vault: vault) }
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
                        Image(systemName: vault.mount != nil && path == vault.bundle?.path ? "lock.open.fill" : "lock.fill")
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
    panel.allowedContentTypes = [UTType(filenameExtension: "sparsebundle")!]
    panel.nameFieldStringValue = name
    return panel.runModal() == .OK ? panel.url.map { URL(filePath: $0.path) } : nil
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
                if creating { Text("Choose its password. Nobody can recover it for you.").foregroundStyle(.secondary) }
                else { BackupStatus(vault: vault) }
                SecureField(creating ? "Password" : "Speak, friend, and enter", text: $password).padding(.top, 8)
                if creating { SecureField("Confirm Password", text: $confirm) }
                Toggle("Remember with Touch ID", isOn: $touchID)
                HStack {
                    if !creating && vault.hasSavedPassword {
                        Button("Touch ID", systemImage: "touchid") { Task { await vault.unlockWithTouchID() } }
                    }
                    Button(creating ? "Create Vault" : "Unlock", action: submit)
                        .buttonStyle(Glowing())
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || creating && password != confirm)
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

struct Item: Identifiable {
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey]
    let url: URL, name: String, kind: String, date: Date, size: Int, isFolder: Bool, icon: NSImage
    var id: URL { url }

    init(_ url: URL) {
        let values = try? url.resourceValues(forKeys: Item.keys)
        (self.url, name, icon) = (url, url.lastPathComponent, NSWorkspace.shared.icon(forFile: url.path))
        kind = values?.localizedTypeDescription ?? ""
        date = values?.contentModificationDate ?? .distantPast
        size = values?.fileSize ?? 0
        isFolder = values?.isDirectory == true && values?.isPackage != true
    }
}

struct Browser: View {
    let vault: Vault
    let root: URL
    @State private var path: [String] = []
    @State private var items: [Item] = []
    @State private var selection = Set<URL>()
    @State private var order = [KeyPathComparator(\Item.name)]
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var doomed: Set<URL>?
    @State private var working = 0
    @State private var targeted = false

    private var dir: URL { path.reduce(root) { $0.appending(path: $1) } }

    var body: some View {
        Table(of: Item.self, selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { item in
                Label { Text(item.name) } icon: { Image(nsImage: item.icon).resizable().frame(width: 16, height: 16) }
            }
            TableColumn("Date Modified", value: \.date) { Text($0.date, format: .dateTime) }
            TableColumn("Size", value: \.size) { Text($0.isFolder ? "--" : $0.size.formatted(.byteCount(style: .file))) }
            TableColumn("Kind", value: \.kind)
        } rows: {
            ForEach(items) { item in TableRow(item).itemProvider { NSItemProvider(contentsOf: item.url) } }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Open") { open(urls) }
            Button("Rename…") { rename(urls.first) }.disabled(urls.count != 1)
            Button("Delete…") { doomed = urls }
        } primaryAction: { open($0) }
        .onDeleteCommand { if !selection.isEmpty { doomed = selection } }
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
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { targeted = $0 }
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
        .navigationSubtitle(path.joined(separator: " › "))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { path.removeLast() }
                    .keyboardShortcut(.upArrow).disabled(path.isEmpty)
            }
            ToolbarItemGroup {
                if working > 0 { ProgressView().controlSize(.small) }
                Button("New Folder", systemImage: "folder.badge.plus", action: newFolder).keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Lock", systemImage: "lock", action: vault.lock).keyboardShortcut("l")
            }
        }
        .onChange(of: path, initial: true) { load() }
        .onChange(of: order) { items.sort(using: order) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in load() }
        .alert("Rename", isPresented: Binding(isPresent: $renaming), presenting: renaming) { url in
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName
                attempt { try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appending(path: name)) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Permanently delete \(doomed?.count ?? 0) item(s)?", isPresented: Binding(isPresent: $doomed), presenting: doomed) { urls in
            Button("Delete", role: .destructive) { attempt { for url in urls { try FileManager.default.removeItem(at: url) } } }
        }
    }

    private func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(Item.keys), options: .skipsHiddenFiles)) ?? []
        items = urls.map(Item.init).sorted(using: order)
    }

    private func open(_ urls: Set<URL>) {
        for item in items where urls.contains(item.url) {
            if item.isFolder { path.append(item.name); return }
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Copies dropped files in; ⌘-drop moves them, so only the encrypted copy remains.
    private func add(_ urls: [URL]) {
        let move = NSEvent.modifierFlags.contains(.command), dir = dir
        attempt {
            for url in urls where url.deletingLastPathComponent().path != dir.path {
                let destination = unique(dir.appending(path: url.lastPathComponent))
                try move ? FileManager.default.moveItem(at: url, to: destination) : FileManager.default.copyItem(at: url, to: destination)
            }
        }
    }

    private func newFolder() {
        let folder = unique(dir.appending(path: "untitled folder"))
        attempt { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        rename(folder)
    }

    private func rename(_ url: URL?) { (newName, renaming) = (url?.lastPathComponent ?? "", url) }

    /// Runs file work off the main thread, then refreshes.
    private func attempt(_ work: @escaping @Sendable () throws -> Void) {
        working += 1
        Task {
            do { try await Task.detached { try work() }.value } catch { vault.error = error.localizedDescription }
            working -= 1
            load()
        }
    }
}

/// `name 2.ext`, `name 3.ext`… like Finder, so nothing is ever overwritten.
func unique(_ url: URL) -> URL {
    let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
    var candidate = url, n = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
        n += 1
        candidate = url.deletingLastPathComponent().appending(path: "\(base) \(n)\(ext)")
    }
    return candidate
}

extension Binding where Value == Bool {
    init<T: Sendable>(isPresent value: Binding<T?>) {
        self.init(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
