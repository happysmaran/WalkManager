import SwiftUI
import UniformTypeIdentifiers
import Combine
import Foundation
import AVFoundation

struct ContentView: View {
    @StateObject private var converter = AudioConverter()
    
    @State private var sourceFolder: URL?
    @State private var destFolder: URL?
    @State private var selectedBitrate: String = "320"
    
    let bitrates = ["128", "192", "256", "320"]
    
    var body: some View {
        VStack(spacing: 24) {
            
            // MARK: - Header
            VStack(spacing: 8) {
                Text("WalkManager")
                    .font(.title)
                    .fontWeight(.semibold)
                
                Text("Batch convert and transfer audio to your USB mp3 device")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 10)
            
            // MARK: - Folder Selection Cards
            HStack(spacing: 20) {
                FolderCard(
                    title: "Music Library",
                    subtitle: "Source Folder",
                    icon: "folder.fill",
                    url: sourceFolder,
                    tint: .blue
                ) {
                    sourceFolder = selectFolder()
                }
                
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                
                FolderCard(
                    title: "mp3 player",
                    subtitle: "Destination",
                    icon: "externaldrive.fill",
                    url: destFolder,
                    tint: .green
                ) {
                    destFolder = selectFolder()
                }
            }
            
            // MARK: - Settings
            GroupBox {
                HStack {
                    Label("MP3 Export Quality", systemImage: "waveform")
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Picker("", selection: $selectedBitrate) {
                        ForEach(bitrates, id: \.self) { bitrate in
                            Text("\(bitrate) kbps").tag(bitrate)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 200)
                }
                .padding(4)
            }
            
            Spacer()
            
            // MARK: - Progress & Action
            VStack(spacing: 12) {
                if converter.isConverting {
                    VStack(spacing: 8) {
                        ProgressView(value: converter.progress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .tint(.blue)
                        
                        Text(converter.statusMessage)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Button(action: {
                        if let src = sourceFolder, let dst = destFolder {
                            converter.startConversion(source: src, destination: dst, bitrate: selectedBitrate)
                        }
                    }) {
                        Label("Convert & Transfer", systemImage: "play.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(sourceFolder == nil || destFolder == nil)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: converter.isConverting)
        }
        .padding(30)
        .frame(width: 550, height: 480)
        // Prevents the window from being resized too small
        .frame(minWidth: 500, minHeight: 450)
    }
    
    // macOS Open Panel for Folder Selection
    func selectFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            return panel.url
        }
        return nil
    }
}

// MARK: - Reusable UI Components
struct FolderCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let url: URL?
    let tint: Color
    let action: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(tint)
                Text(subtitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            
            Text(url?.lastPathComponent ?? "Select \(title)")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Button(action: action) {
                Text("Browse...")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Converter Logic
class AudioConverter: ObservableObject {
    @Published var isConverting = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""
    
    let supportedExtensions = ["wav", "flac", "m4a", "aac", "aiff", "ogg", "alac", "mp3", "wma"]
    
    func startConversion(source: URL, destination: URL, bitrate: String) {
        isConverting = true
        progress = 0.0
        statusMessage = "Scanning for audio files..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            
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
            
            // Set up a multi-threading queue
            let queue = OperationQueue()
            // Launch as many parallel conversions as you have CPU cores
            queue.maxConcurrentOperationCount = ProcessInfo.processInfo.processorCount
            
            var completedCount = 0
            
            for file in audioFiles {
                queue.addOperation {
                    let fileExtension = file.pathExtension.lowercased()
                    let filenameWithoutExtension = file.deletingPathExtension().lastPathComponent
                    let outputURL = destination.appendingPathComponent("\(filenameWithoutExtension).mp3")
                    
                    if fileExtension == "mp3" {
                        let currentKbps = self.estimateBitrate(for: file)
                        
                        if currentKbps > (targetKbps + 15.0) {
                            self.convertToMP3(input: file, output: outputURL, bitrate: bitrate)
                        } else {
                            do {
                                if fileManager.fileExists(atPath: outputURL.path) {
                                    try fileManager.removeItem(at: outputURL)
                                }
                                try fileManager.copyItem(at: file, to: outputURL)
                            } catch {
                                print("Failed to copy MP3: \(error.localizedDescription)")
                            }
                        }
                    } else {
                        self.convertToMP3(input: file, output: outputURL, bitrate: bitrate)
                    }
                    
                    // Update progress safely on the main thread
                    DispatchQueue.main.async {
                        completedCount += 1
                        self.progress = Double(completedCount) / Double(totalFiles)
                        self.statusMessage = "Processed \(completedCount) of \(totalFiles)"
                    }
                }
            }
            
            // Wait for all the parallel background tasks to finish
            queue.waitUntilAllOperationsAreFinished()
            
            self.updateUI {
                self.statusMessage = "Done! Successfully transferred \(totalFiles) files."
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
