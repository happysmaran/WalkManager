import SwiftUI
import UniformTypeIdentifiers
import Combine
import Foundation
import AVFoundation
import DiskArbitration
import AppKit

// MARK: - Root View

struct ContentView: View {
    @StateObject private var converter = AudioConverter()
    @StateObject private var deviceManager = DeviceManager()

    @State private var sourceFolder: URL?
    @State private var selectedBitrate: String = "320"
    @State private var selectedDeviceID: String?

    let bitrates = ["128", "192", "256", "320"]

    var selectedDevice: ConnectedDevice? {
        deviceManager.devices.first { $0.id == selectedDeviceID }
    }

    var body: some View {
        NavigationSplitView {
            // MARK: Sidebar - "Devices" (iTunes left pane)
            List(selection: $selectedDeviceID) {
                Section("Devices") {
                    if deviceManager.devices.isEmpty {
                        Text("No USB devices connected")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(deviceManager.devices) { device in
                            Label(device.displayName, systemImage: device.iconName)
                                .tag(device.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .onAppear { deviceManager.startMonitoring() }
            .onChange(of: deviceManager.devices) { _, newDevices in
                if selectedDeviceID == nil {
                    selectedDeviceID = newDevices.first?.id
                    if let first = newDevices.first { loadSettings(for: first) }
                }
                if let current = selectedDeviceID, !newDevices.contains(where: { $0.id == current }) {
                    selectedDeviceID = newDevices.first?.id
                    if let first = newDevices.first { loadSettings(for: first) }
                }
            }
        } detail: {
            // MARK: Detail - device summary panel
            if let device = selectedDevice {
                DeviceDetailView(
                    device: device,
                    converter: converter,
                    sourceFolder: sourceFolder,
                    selectedBitrate: $selectedBitrate,
                    bitrates: bitrates,
                    onConvert: {
                        if let src = sourceFolder {
                            let forceOverwrite = NSEvent.modifierFlags.contains(.option)
                            converter.startConversion(source: src, destination: device.effectiveDestinationURL, bitrate: selectedBitrate, forceOverwrite: forceOverwrite)
                        }
                    },
                    onPickFolderManually: {
                        if let picked = selectFolder() {
                            sourceFolder = picked
                            saveSettings(for: device)
                        }
                    },
                    onMusicSubfolderChanged: {
                        saveSettings(for: device)
                    }
                )
                .id(device.id) // refresh song list etc. when switching devices
            } else {
                EmptyStateView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: selectedDeviceID) { _, _ in
            if let device = selectedDevice {
                loadSettings(for: device)
            }
        }
        .onChange(of: selectedBitrate) { _, _ in
            if let device = selectedDevice {
                saveSettings(for: device)
            }
        }
    }

    func selectFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Applies any remembered bitrate / destination subfolder / source folder
    /// for this device. Only overrides the source folder if the user hasn't
    /// already picked one this session, so we never silently yank a folder
    /// out from under an in-progress choice.
    private func loadSettings(for device: ConnectedDevice) {
        guard let saved = DeviceSettingsStore.shared.settings(for: device.identityKey) else { return }
        selectedBitrate = saved.bitrate
        if device.candidateMusicFolders.contains(saved.musicSubfolder) || saved.musicSubfolder.isEmpty {
            device.selectedMusicFolder = saved.musicSubfolder
        }
        if sourceFolder == nil, let resolved = DeviceSettingsStore.shared.resolveSourceFolder(for: device.identityKey) {
            sourceFolder = resolved
        }
    }

    private func saveSettings(for device: ConnectedDevice) {
        DeviceSettingsStore.shared.save(
            bitrate: selectedBitrate,
            musicSubfolder: device.selectedMusicFolder,
            sourceFolder: sourceFolder,
            for: device.identityKey
        )
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("No Device Selected")
                .font(.title3)
                .fontWeight(.medium)
            Text("Plug in a USB mass-storage device and select it in the sidebar.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Device Detail (iTunes-style summary)

struct DeviceDetailView: View {
    @ObservedObject var device: ConnectedDevice
    @ObservedObject var converter: AudioConverter

    let sourceFolder: URL?
    @Binding var selectedBitrate: String
    let bitrates: [String]
    let onConvert: () -> Void
    let onPickFolderManually: () -> Void
    let onMusicSubfolderChanged: () -> Void

    @State private var existingTracks: [AudioTrackInfo] = []
    @State private var isScanningTracks = false
    @State private var isOptionHeld = false
    @State private var flagsMonitor: Any?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // MARK: Device header card
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: device.iconName)
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)
                        .frame(width: 64, height: 64)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.displayName)
                            .font(.title2)
                            .fontWeight(.semibold)

                        if let vendor = device.vendor, let model = device.model {
                            Text("\(vendor) \(model)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            Text("USB Mass Storage Device")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Text("Detected as a removable volume. Vendor/model information is reported by the device itself and may be generic.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // MARK: Storage bar
                StorageBarView(device: device)

                Divider()

                // MARK: Sync settings
                GroupBox("Sync Settings") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Music Folder", systemImage: "folder")
                            Spacer()
                            Text(sourceFolder?.path ?? "Not selected")
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose...", action: onPickFolderManually)
                        }

                        HStack {
                            Label("Destination on Device", systemImage: "arrow.down.doc")
                            Spacer()
                            Picker("", selection: Binding(
                                get: { device.selectedMusicFolder },
                                set: { device.selectedMusicFolder = $0; onMusicSubfolderChanged() }
                            )) {
                                Text("Device Root").tag("")
                                ForEach(device.candidateMusicFolders, id: \.self) { folder in
                                    Text(folder).tag(folder)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 160, alignment: .trailing)
                        }

                        HStack {
                            Label("MP3 Export Quality", systemImage: "waveform")
                            Spacer()
                            Picker("", selection: $selectedBitrate) {
                                ForEach(bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 160, alignment: .trailing)
                        }
                    }
                    .padding(6)
                }

                // MARK: Convert / Progress
                VStack(spacing: 10) {
                    if converter.isConverting {
                        ProgressView(value: converter.progress)
                            .tint(.accentColor)
                        Text(converter.statusMessage)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        Button(action: onConvert) {
                            Label(
                                isOptionHeld ? "Overwrite & Transfer to \(device.displayName)" : "Convert & Transfer to \(device.displayName)",
                                systemImage: isOptionHeld ? "arrow.triangle.2.circlepath.circle.fill" : "play.circle.fill"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isOptionHeld ? .orange : .accentColor)
                        .controlSize(.large)
                        .disabled(sourceFolder == nil)
                        .animation(.easeInOut(duration: 0.12), value: isOptionHeld)

                        Text(isOptionHeld
                             ? "Release to add new songs only. Overwrite mode will delete and re-write any songs already on the device."
                             : "Adds new songs only, and never touches existing files on the device. Hold ⌥ Option while clicking to overwrite (delete + re-write) any songs already there.")
                            .font(.caption)
                            .foregroundColor(isOptionHeld ? .orange : .secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .animation(.easeInOut, value: converter.isConverting)

                Divider()

                // MARK: On-device song list
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Songs on Device")
                            .font(.headline)
                        Spacer()
                        if isScanningTracks {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("\(existingTracks.count) tracks")
                                .foregroundColor(.secondary)
                        }
                        Button {
                            scanExistingTracks()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                    }

                    if existingTracks.isEmpty && !isScanningTracks {
                        Text("No audio files found on this device yet.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        TrackTableView(tracks: existingTracks, onDelete: deleteTrack)
                            .frame(minHeight: 220)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            scanExistingTracks()
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                isOptionHeld = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
        }
        .onChange(of: converter.isConverting) { _, converting in
            if converting == false {
                scanExistingTracks()
                device.refreshCapacity()
            }
        }
        .onChange(of: device.selectedMusicFolder) { _, _ in
            scanExistingTracks()
        }
    }

    private func scanExistingTracks() {
        isScanningTracks = true
        let mountURL = device.effectiveDestinationURL
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var results: [AudioTrackInfo] = []
            if let enumerator = fm.enumerator(at: mountURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.pathExtension.lowercased() == "mp3" else { continue }
                    let asset = AVURLAsset(url: fileURL)
                    let duration = CMTimeGetSeconds(asset.duration)
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    results.append(
                        AudioTrackInfo(
                            id: fileURL.path,
                            fileURL: fileURL,
                            title: fileURL.deletingPathExtension().lastPathComponent,
                            durationSeconds: duration.isFinite ? duration : 0,
                            fileSizeBytes: size
                        )
                    )
                }
            }
            results.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            DispatchQueue.main.async {
                self.existingTracks = results
                self.isScanningTracks = false
            }
        }
    }

    private func deleteTrack(_ track: AudioTrackInfo) {
        do {
            try FileManager.default.removeItem(at: track.fileURL)
        } catch {
            print("Failed to delete track: \(error.localizedDescription)")
        }
        device.refreshCapacity()
        scanExistingTracks()
    }
}

// MARK: - Storage Bar (iTunes-style capacity breakdown)

struct StorageBarView: View {
    @ObservedObject var device: ConnectedDevice

    var usedFraction: Double {
        guard device.totalCapacity > 0 else { return 0 }
        return Double(device.usedCapacity) / Double(device.totalCapacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.separatorColor).opacity(0.3))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor)
                            .frame(width: max(4, geo.size.width * usedFraction))
                    }
            }
            .frame(height: 18)

            HStack {
                Label(byteString(device.usedCapacity) + " used", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Spacer()
                Label(byteString(device.availableCapacity) + " free", systemImage: "circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(byteString(device.totalCapacity) + " capacity")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Track table

struct TrackTableView: View {
    let tracks: [AudioTrackInfo]
    let onDelete: (AudioTrackInfo) -> Void

    @State private var pendingDeletion: AudioTrackInfo?

    var body: some View {
        Table(tracks) {
            TableColumn("Title") { track in
                Text(track.title)
            }
            TableColumn("Duration") { track in
                Text(track.durationDisplay)
                    .foregroundColor(.secondary)
            }
            .width(80)
            TableColumn("Size") { track in
                Text(track.sizeDisplay)
                    .foregroundColor(.secondary)
            }
            .width(90)
            TableColumn("") { track in
                Button {
                    pendingDeletion = track
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            .width(30)
        }
        .alert(item: $pendingDeletion) { track in
            Alert(
                title: Text("Delete \"\(track.title)\" from device?"),
                message: Text("This permanently removes the file from the device. It does not affect your source library."),
                primaryButton: .destructive(Text("Delete")) {
                    onDelete(track)
                },
                secondaryButton: .cancel()
            )
        }
    }
}

struct AudioTrackInfo: Identifiable {
    let id: String
    let fileURL: URL
    let title: String
    let durationSeconds: Double
    let fileSizeBytes: Int

    var durationDisplay: String {
        let total = Int(durationSeconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSizeBytes), countStyle: .file)
    }
}

extension AudioTrackInfo: Equatable {
    static func == (lhs: AudioTrackInfo, rhs: AudioTrackInfo) -> Bool { lhs.id == rhs.id }
}

// MARK: - Connected device model

final class ConnectedDevice: ObservableObject, Identifiable, Equatable {
    let id: String                 // BSD name, e.g. "disk4s1"
    let mountURL: URL
    @Published var volumeName: String
    @Published var vendor: String?
    @Published var model: String?
    @Published var totalCapacity: Int64
    @Published var availableCapacity: Int64
    @Published var isRemovable: Bool

    /// Top-level folders on the device that look like conventional music
    /// destinations (e.g. "MUSIC", "Music"). Populated by DeviceManager
    /// when the device is scanned. Always includes an explicit "root" option
    /// so writing to the volume's top level is a deliberate choice, not a
    /// silent default.
    @Published var candidateMusicFolders: [String] = []

    /// The folder (relative to the volume root) that transfers should write
    /// into. Empty string = device root. Defaults to the first detected
    /// music-like folder if one exists, otherwise root -- but is always
    /// shown and editable in the UI rather than assumed silently.
    @Published var selectedMusicFolder: String = ""

    init(id: String, mountURL: URL, volumeName: String, vendor: String?, model: String?,
         totalCapacity: Int64, availableCapacity: Int64, isRemovable: Bool) {
        self.id = id
        self.mountURL = mountURL
        self.volumeName = volumeName
        self.vendor = vendor
        self.model = model
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.isRemovable = isRemovable
    }

    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    var displayName: String {
        volumeName.isEmpty ? (vendor ?? "USB Device") : volumeName
    }

    /// The actual destination URL transfers should be written to, given the
    /// currently selected folder (root or a detected/custom subfolder).
    var effectiveDestinationURL: URL {
        selectedMusicFolder.isEmpty ? mountURL : mountURL.appendingPathComponent(selectedMusicFolder)
    }

    /// A stable-ish identity for persisting per-device settings. The BSD name
    /// (`id`) can change across reconnects/reboots, so instead we key off
    /// whatever the device itself reports (vendor + model + volume name).
    /// Not perfectly unique (two identical drives with the same volume name
    /// would collide), but it's the best signal macOS gives us for generic
    /// USB mass storage, consistent with the detection limits discussed
    /// earlier. I love Unix.
    var identityKey: String {
        let parts = [vendor, model, volumeName].compactMap { $0 }.joined(separator: "|")
        return parts.isEmpty ? "unknown-device" : parts.lowercased()
    }

    /// Re-reads live capacity from the volume, used after deleting or
    /// transferring individual files so the storage bar stays accurate
    /// without waiting for the next full device rescan.
    func refreshCapacity() {
        guard let values = try? mountURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) else { return }
        if let total = values.volumeTotalCapacity { self.totalCapacity = Int64(total) }
        if let available = values.volumeAvailableCapacity { self.availableCapacity = Int64(available) }
    }

    /// NOTE: macOS cannot positively identify a device as an "MP3 player" vs. a plain
    /// USB flash drive -- both present as generic USB Mass Storage volumes. This icon
    /// is only a best-effort guess based on the vendor/model strings the device reports.
    var iconName: String {
        let haystack = ((vendor ?? "") + " " + (model ?? "") + " " + volumeName).lowercased()
        let playerHints = ["walkman", "mp3", "player", "sansa", "clip", "nano", "ipod"]
        if playerHints.contains(where: { haystack.contains($0) }) {
            return "ipod"
        }
        return "externaldrive.fill"
    }

    static func == (lhs: ConnectedDevice, rhs: ConnectedDevice) -> Bool {
        lhs.id == rhs.id &&
        lhs.volumeName == rhs.volumeName &&
        lhs.totalCapacity == rhs.totalCapacity &&
        lhs.availableCapacity == rhs.availableCapacity
    }
}

// MARK: - Persisted per-device settings
//
// Remembers, per device, the last-used MP3 bitrate, destination subfolder,
// and source music folder.

struct DeviceSyncSettings: Codable {
    var bitrate: String
    var musicSubfolder: String
    var sourceFolderBookmark: Data?
}

final class DeviceSettingsStore {
    static let shared = DeviceSettingsStore()

    private let defaultsKey = "WalkManager.DeviceSyncSettings"
    private var cache: [String: DeviceSyncSettings]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: DeviceSyncSettings].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func settings(for identityKey: String) -> DeviceSyncSettings? {
        cache[identityKey]
    }

    func save(bitrate: String, musicSubfolder: String, sourceFolder: URL?, for identityKey: String) {
        var bookmark: Data?
        if let sourceFolder {
            bookmark = try? sourceFolder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        cache[identityKey] = DeviceSyncSettings(bitrate: bitrate, musicSubfolder: musicSubfolder, sourceFolderBookmark: bookmark)
        persist()
    }

    /// Resolves a stored bookmark back into a usable URL. Starts the
    /// security-scoped access; callers should call `stopAccessingSecurityScopedResource()`
    /// on the returned URL when they're done with it for this session (WalkManager
    /// keeps access open for the lifetime of the selection, matching the
    /// existing NSOpenPanel-driven folder picker behavior).
    func resolveSourceFolder(for identityKey: String) -> URL? {
        guard let bookmark = cache[identityKey]?.sourceFolderBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - Device Manager
//
// Uses DiskArbitration to enumerate mounted, removable, ejectable volumes and
// pull whatever vendor/model metadata the device itself reports.

final class DeviceManager: NSObject, ObservableObject {
    @Published var devices: [ConnectedDevice] = []

    private var session: DASession?
    private let notificationCenter = NotificationCenter.default

    func startMonitoring() {
        guard session == nil else { return }

        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionSetDispatchQueue(session, DispatchQueue.main)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            let manager = Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue()
            manager.refreshDevices()
        }, selfPtr)

        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            let manager = Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue()
            manager.refreshDevices()
        }, selfPtr)

        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, keys, context in
            let manager = Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue()
            manager.refreshDevices()
        }, selfPtr)

        refreshDevices()
    }

    func refreshDevices() {
        let fm = FileManager.default
        guard let mountedVolumeURLs = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey],
            options: [.skipHiddenVolumes]
        ) else {
            self.devices = []
            return
        }

        guard let session = session else { return }

        var results: [ConnectedDevice] = []

        for volumeURL in mountedVolumeURLs {
            guard let values = try? volumeURL.resourceValues(forKeys: [
                .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey,
                .volumeTotalCapacityKey, .volumeAvailableCapacityKey
            ]) else { continue }

            let isRemovable = values.volumeIsRemovable ?? false
            let isEjectable = values.volumeIsEjectable ?? false
            // Only show devices that look like external USB media, not the boot volume.
            guard isRemovable || isEjectable else { continue }

            let volumeName = values.volumeName ?? volumeURL.lastPathComponent
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let available = Int64(values.volumeAvailableCapacity ?? 0)

            var vendor: String?
            var model: String?
            var bsdName = volumeURL.path

            if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
               let descCF = DADiskCopyDescription(disk) {
                let desc = descCF as NSDictionary
                vendor = (desc[kDADiskDescriptionDeviceVendorKey as String] as? String)?
                    .trimmingCharacters(in: .whitespaces)
                model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String)?
                    .trimmingCharacters(in: .whitespaces)
                if let name = DADiskGetBSDName(disk) {
                    bsdName = String(cString: name)
                }
            }

            let newDevice = ConnectedDevice(
                id: bsdName,
                mountURL: volumeURL,
                volumeName: volumeName,
                vendor: (vendor?.isEmpty ?? true) ? nil : vendor,
                model: (model?.isEmpty ?? true) ? nil : model,
                totalCapacity: total,
                availableCapacity: available,
                isRemovable: isRemovable
            )

            // Detect conventional top-level music folders so we don't silently
            // guess where to write. Devices vary: some want files at the
            // volume root, some expect a dedicated MUSIC/Music folder, some
            // use other vendor-specific names -- so we surface whatever
            // matches and let the user confirm, rather than assuming.
            let musicFolderHints = ["music", "mp3", "songs", "audio"]
            if let contents = try? fm.contentsOfDirectory(at: volumeURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                let matches = contents.filter { url in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    return isDir && musicFolderHints.contains(url.lastPathComponent.lowercased())
                }.map { $0.lastPathComponent }
                newDevice.candidateMusicFolders = matches.sorted()
                // Preserve the user's existing choice on refresh; otherwise
                // default to the first detected folder, falling back to root.
                if let previous = self.devices.first(where: { $0.id == bsdName }) {
                    newDevice.selectedMusicFolder = previous.selectedMusicFolder
                } else {
                    newDevice.selectedMusicFolder = matches.first ?? ""
                }
            }

            results.append(newDevice)
        }

        self.devices = results.sorted { $0.displayName < $1.displayName }
    }
}

// MARK: - Converter Logic (unchanged conversion behavior, destination now = selected device mount)

class AudioConverter: ObservableObject {
    @Published var isConverting = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""

    let supportedExtensions = ["wav", "flac", "m4a", "aac", "aiff", "ogg", "alac", "mp3", "wma"]

    func startConversion(source: URL, destination: URL, bitrate: String, forceOverwrite: Bool) {
        isConverting = true
        progress = 0.0
        statusMessage = forceOverwrite ? "Scanning for audio files (overwrite mode)..." : "Scanning for audio files..."

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            // Make sure the chosen destination (root or a subfolder like
            // "MUSIC") actually exists before writing into it.
            if !fileManager.fileExists(atPath: destination.path) {
                do {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                } catch {
                    self.updateUI {
                        self.statusMessage = "Could not create destination folder: \(error.localizedDescription)"
                        self.isConverting = false
                    }
                    return
                }
            }

            guard let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: nil) else {
                self.updateUI { self.statusMessage = "Failed to read source folder."; self.isConverting = false }
                return
            }

            var audioFiles: [URL] = []

            for case let fileURL as URL in enumerator {
                if self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    audioFiles.append(fileURL)
                }
            }

            let totalFiles = audioFiles.count
            if totalFiles == 0 {
                self.updateUI { self.statusMessage = "No supported audio files found."; self.isConverting = false }
                return
            }

            let targetKbps = Double(bitrate) ?? 320.0

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = ProcessInfo.processInfo.processorCount

            var completedCount = 0
            var transferredCount = 0
            var skippedCount = 0
            let progressLock = NSLock()

            for file in audioFiles {
                queue.addOperation {
                    let fileExtension = file.pathExtension.lowercased()
                    let filenameWithoutExtension = file.deletingPathExtension().lastPathComponent
                    let outputURL = destination.appendingPathComponent("\(filenameWithoutExtension).mp3")

                    let alreadyOnDevice = fileManager.fileExists(atPath: outputURL.path)
                    var wasSkipped = false

                    // Default behavior: never touch a file that's already on the
                    // device -- no re-encode, no re-copy, no delete. Only
                    // force-overwrite (Option key) actually deletes and re-writes
                    // an existing file; everything else that's new gets added.
                    if alreadyOnDevice && !forceOverwrite {
                        wasSkipped = true
                    } else {
                        if alreadyOnDevice && forceOverwrite {
                            do {
                                try fileManager.removeItem(at: outputURL)
                            } catch {
                                print("Failed to remove existing file before overwrite: \(error.localizedDescription)")
                            }
                        }

                        if fileExtension == "mp3" {
                            let currentKbps = self.estimateBitrate(for: file)

                            if currentKbps > (targetKbps + 15.0) {
                                self.convertToMP3(input: file, output: outputURL, bitrate: bitrate)
                            } else {
                                do {
                                    try fileManager.copyItem(at: file, to: outputURL)
                                } catch {
                                    print("Failed to copy MP3: \(error.localizedDescription)")
                                }
                            }
                        } else {
                            self.convertToMP3(input: file, output: outputURL, bitrate: bitrate)
                        }
                    }

                    progressLock.lock()
                    completedCount += 1
                    if wasSkipped { skippedCount += 1 } else { transferredCount += 1 }
                    let currentCompleted = completedCount
                    let currentTransferred = transferredCount
                    let currentSkipped = skippedCount
                    progressLock.unlock()

                    DispatchQueue.main.async {
                        self.progress = Double(currentCompleted) / Double(totalFiles)
                        self.statusMessage = "Processed \(currentCompleted) of \(totalFiles) (\(currentTransferred) transferred, \(currentSkipped) already on device)"
                    }
                }
            }

            queue.waitUntilAllOperationsAreFinished()

            self.updateUI {
                self.statusMessage = "Done! \(transferredCount) transferred, \(skippedCount) already on device left untouched."
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.isConverting = false
                }
            }
        }
    }

    private func estimateBitrate(for url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = resourceValues.fileSize {
                let duration = CMTimeGetSeconds(asset.duration)
                if duration > 0 {
                    return (Double(fileSize) * 8.0) / duration / 1000.0
                }
            }
        } catch {
            print("Could not read file size for bitrate estimation.")
        }
        return 999.0
    }

    private func convertToMP3(input: URL, output: URL, bitrate: String) {
        let process = Process()
        let fm = FileManager.default

        var ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        if !fm.fileExists(atPath: ffmpegPath) {
            ffmpegPath = "/usr/local/bin/ffmpeg"
        }

        if !fm.fileExists(atPath: ffmpegPath) {
            print("ERROR: FFmpeg not found at \(ffmpegPath).")
            return
        }

        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        process.arguments = [
            "-y",
            "-i", input.path,
            "-map_metadata", "0",
            "-codec:a", "libmp3lame",
            "-b:a", "\(bitrate)k",
            "-write_id3v1", "1",
            "-id3v2_version", "3",
            output.path
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Failed to run FFmpeg: \(error.localizedDescription)")
        }
    }

    private func updateUI(_ block: @escaping () -> Void) {
        DispatchQueue.main.async {
            block()
        }
    }
}
