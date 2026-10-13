import SwiftUI

/// The Google Cloud CLI owns sign-in and credentials; Moria only drives it. It goes through a login shell so it finds
/// `gcloud`, and the Python it runs on, just like Terminal does.
enum GCloud {
    private static let script = #"command -v gcloud >/dev/null || { echo "Install the Google Cloud CLI first: brew install --cask gcloud-cli" >&2; exit 127; }; gcloud "$@""#

    @discardableResult
    static func run(_ args: String...) async throws -> String {
        try await Task.detached { try sh("/bin/zsh", ["-lc", script, "gcloud"] + args) }.value
    }

    /// The project's Moria bucket. With `create`, a project without one gets a private one.
    static func bucket(in project: String, create: Bool = false) async throws -> String? {
        let existing = try await run("storage", "buckets", "list", "--project", project, "--filter=name~^moria-", "--format=value(name)")
        if let name = existing.split(separator: "\n").first { return String(name) }
        guard create else { return nil }
        let name = "moria-\(UUID().uuidString.prefix(8).lowercased())"
        try await run("storage", "buckets", "create", "gs://\(name)", "--project", project, "--location", "US",
                      "--uniform-bucket-level-access", "--public-access-prevention")
        return name
    }

    /// The vaults backed up in `bucket`, one folder each, with sizes and dates added up from their objects.
    static func backups(in bucket: String) async throws -> [Backup] {
        var backups: [String: Backup] = [:]
        for object in try await run("storage", "objects", "list", "gs://\(bucket)/**", "--format=value(name,size,update_time.date(%s))").split(separator: "\n") {
            let fields = object.split(separator: "\t")
            guard fields.count == 3, let slash = fields[0].firstIndex(of: "/"), slash > fields[0].startIndex else { continue }
            let id = "gs://\(bucket)/\(fields[0][..<slash])"
            backups[id, default: Backup(id: id)].size += Int(fields[1]) ?? 0
            backups[id]!.date = max(backups[id]!.date, Date(timeIntervalSince1970: Double(fields[2]) ?? 0))
        }
        return backups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A vault's folder in the bucket.
struct Backup: Identifiable {
    let id: String  // gs://moria-…/Name-1a2b3c
    var size = 0
    var date = Date.distantPast
    /// Without the suffix that keeps two vaults of the same name apart.
    var name: String { String(id.split(separator: "/").last ?? "").replacing(#/-[0-9a-f]{6}$/#, with: "") }
}

struct CloudSheet: View {
    let vault: Vault
    @Environment(\.dismiss) private var dismiss
    @AppStorage("project") private var project = ""
    @State private var account: String?
    @State private var projects: [String] = []
    @State private var backups: [Backup]?
    @State private var elsewhere: [String: String] = [:]  // remote → path of another vault here backing up to it
    @State private var working = false
    @State private var error: String?
    @State private var unbilled: String?
    @State private var doomed: Backup?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Account") {
                        if let account { Text(account) } else {
                            Button("Sign in with Google") { perform { try await GCloud.run("auth", "login", "--brief"); try await refresh() } }
                        }
                    }
                    if account != nil { Picker("Project", selection: $project) { ForEach(projects, id: \.self) { Text($0) } } }
                } header: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Google Cloud", systemImage: "cloud.fill").font(.title2.bold()).foregroundStyle(.ithildin)
                        Text("Vaults back up whenever they lock. Google only ever sees encrypted blocks.").foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 8)
                }
                if account != nil && vault.exists {
                    Section("This Vault") {
                        LabeledContent {
                            if let remote = vault.remote { Button("Disconnect") { vault.unlink(remote) } }
                            else { Button("Back Up Here") { perform(connect) }.buttonStyle(Glowing()).disabled(project.isEmpty) }
                        } label: {
                            Text(vault.name)
                            BackupStatus(vault: vault)
                        }
                    }
                }
                if let backups {
                    Section("Vaults in \(project)") {
                        ForEach(backups, content: row)
                        if backups.isEmpty { Text("Nothing is backed up here yet.").foregroundStyle(.secondary) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520, height: 560)
        .task { perform(refresh) }
        .task(id: account == nil ? "" : project) { if account != nil { perform(list) } }
        .alert(error ?? "", isPresented: Binding(isPresent: $error)) {}
        .alert("Turn on billing for \(unbilled ?? "")", isPresented: Binding(isPresent: $unbilled), presenting: unbilled) { project in
            Button("Open Billing Settings") {
                NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/billing/linkedaccount?project=\(project)")!)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Google Cloud needs a billing account linked to the project before it can store backups. Link one, then try again.")
        }
        .confirmationDialog("Delete “\(doomed?.name ?? "")” from Google Cloud?", isPresented: Binding(isPresent: $doomed), presenting: doomed) { backup in
            Button("Delete Backup", role: .destructive) { delete(backup) }
        } message: { backup in
            Text(backup.id == vault.remote || elsewhere[backup.id] != nil
                 ? "The vault on this Mac stays as it is, but stops backing up."
                 : "No vault on this Mac matches it, so this may be the only copy. Soft delete keeps it recoverable for 7 days.")
        }
    }

    private func row(_ backup: Backup) -> some View {
        LabeledContent {
            HStack {
                if backup.id == vault.remote { Text("This vault").foregroundStyle(.ithildin) }
                else if elsewhere[backup.id] != nil { Text("On this Mac").foregroundStyle(.secondary) }
                else { Button("Restore…") { restore(backup) } }
                Button("Delete", systemImage: "trash", role: .destructive) { doomed = backup }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        } label: {
            Text(backup.name)
            Text("\(backup.size.formatted(.byteCount(style: .file))) · \(backup.date.formatted(.relative(presentation: .named)))")
        }
        .disabled(working)
    }

    private func connect() async throws {
        // Only stop when Google says billing is off; if the check itself fails, bucket creation reports the real problem.
        if (try? await GCloud.run("billing", "projects", "describe", project, "--format=value(billingEnabled)")) == "False" {
            unbilled = project
            return
        }
        if let bucket = try await GCloud.bucket(in: project, create: true) { vault.link(bucket) }
    }

    private func refresh() async throws {
        let active = try await GCloud.run("auth", "list", "--filter=status:ACTIVE", "--format=value(account)")
        guard !active.isEmpty else { return account = nil }
        projects = try await GCloud.run("projects", "list", "--format=value(projectId)").split(separator: "\n").map(String.init)
        if !projects.contains(project) { project = try await GCloud.run("config", "get-value", "project") }
        if !projects.contains(project) { project = projects.first ?? "" }
        account = active
    }

    private func list() async throws {
        let project = project
        backups = nil
        var found: [Backup] = []
        if let bucket = try await GCloud.bucket(in: project) { found = try await GCloud.backups(in: bucket) }
        guard project == self.project else { return }  // Switched projects meanwhile.
        backups = found
        elsewhere = Dictionary(vault.vaults.compactMap { path in Vault.attribute("moria.remote", of: path).map { ($0, path) } }) { a, _ in a }
    }

    /// Downloads a backup to a new bundle, which keeps backing up to it.
    private func restore(_ backup: Backup) {
        guard let url = pickVault(NSSavePanel(), name: backup.name) else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else { return error = "Restoring never overwrites a vault. Choose a new name." }
        perform {
            try await GCloud.run("storage", "rsync", "-r", backup.id, url.path)
            vault.restored(url, from: backup.id)
            dismiss()
        }
    }

    private func delete(_ backup: Backup) {
        perform {
            try await GCloud.run("storage", "rm", "-r", backup.id + "/")
            vault.unlink(backup.id)
            backups?.removeAll { $0.id == backup.id }
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        working = true
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

struct BackupStatus: View {
    let vault: Vault

    var body: some View {
        Group {
            if vault.syncing {
                Label { Text("Backing up to Google Cloud…") } icon: { ProgressView().controlSize(.small) }
            } else if let date = vault.lastBackup {
                Label("Backed up \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
            } else if vault.remote != nil {
                Label("Not backed up yet", systemImage: "exclamationmark.icloud")
            } else {
                Label("Not backed up", systemImage: "icloud.slash")
            }
        }
        .foregroundStyle(.secondary)
    }
}
