use rayon::prelude::*;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

// Public types
const SUPPORTED_EXTENSIONS: &[&str] = &[
    "wav", "flac", "m4a", "aac", "aiff", "ogg", "alac", "mp3", "wma",
];

/// Shared state for the conversion worker thread.  The UI reads this
/// periodically to update the progress bar and status label.
#[derive(Debug, Default)]
pub struct ConverterState {
    pub is_converting: bool,
    pub progress: f64,
    pub status_message: String,
    /// Set to 'true' for one tick once a conversion completes so the
    /// app can trigger a track-list refresh.
    pub just_finished: bool,
}

/// A single MP3 track on the device.
#[derive(Debug, Clone)]
pub struct AudioTrackInfo {
    pub file_path: PathBuf,
    pub title: String,
    pub duration_display: String,
    pub size_display: String,
}

// Track scanning

/// Scan 'destination' for MP3 files.  Duration is read via ffprobe when
/// available; falls back to "—" if ffprobe isn't on PATH.
pub fn scan_tracks(destination: &Path) -> Vec<AudioTrackInfo> {
    let ffprobe = find_tool("ffprobe");

    // Collect all .mp3 paths first so we can parallelise the ffprobe calls.
    let mp3_paths: Vec<PathBuf> = walkdir::WalkDir::new(destination)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.file_type().is_file()
                && e.path()
                    .extension()
                    .map(|x| x.to_string_lossy().to_lowercase() == "mp3")
                    .unwrap_or(false)
        })
        .map(|e| e.path().to_path_buf())
        .collect();

    let mut tracks: Vec<AudioTrackInfo> = mp3_paths
        .par_iter()
        .map(|path| {
            let title = path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();

            let size_bytes = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            let size_display = format_bytes(size_bytes);

            let duration_display = ffprobe
                .as_deref()
                .and_then(|p| probe_duration(p, path))
                .unwrap_or_else(|| "—".to_string());

            AudioTrackInfo {
                file_path: path.clone(),
                title,
                duration_display,
                size_display,
            }
        })
        .collect();

    tracks.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    tracks
}

fn probe_duration(ffprobe: &Path, audio: &Path) -> Option<String> {
    let out = std::process::Command::new(ffprobe)
        .args([
            "-v",
            "quiet",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            &audio.to_string_lossy(),
        ])
        .output()
        .ok()?;

    let secs: f64 = String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse()
        .ok()?;

    let total = secs as u64;
    Some(format!("{}:{:02}", total / 60, total % 60))
}

// Conversion

/// Spawn a background thread that converts all supported audio files in
/// 'source' to MP3 and copies them into 'destination'.
///
/// 'state' is updated throughout so the UI can show live progress.
pub fn start_conversion(
    source: PathBuf,
    destination: PathBuf,
    bitrate: String,
    force_overwrite: bool,
    state: Arc<Mutex<ConverterState>>,
) {
    std::thread::spawn(move || {
        // initial state
        {
            let mut s = state.lock().unwrap();
            s.is_converting = true;
            s.progress = 0.0;
            s.just_finished = false;
            s.status_message = if force_overwrite {
                "Scanning for audio files (overwrite mode)…".into()
            } else {
                "Scanning for audio files…".into()
            };
        }

        // find ffmpeg
        let ffmpeg = match find_tool("ffmpeg") {
            Some(p) => p,
            None => {
                let mut s = state.lock().unwrap();
                s.status_message =
                    "FFmpeg not found. Install it and make sure it is on your PATH.".into();
                s.is_converting = false;
                return;
            }
        };

        // ensure destination exists
        if !destination.exists() {
            if let Err(e) = std::fs::create_dir_all(&destination) {
                let mut s = state.lock().unwrap();
                s.status_message = format!("Could not create destination folder: {}", e);
                s.is_converting = false;
                return;
            }
        }

        // collect source files
        let audio_files: Vec<PathBuf> = walkdir::WalkDir::new(&source)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_type().is_file()
                    && e.path()
                        .extension()
                        .map(|x| {
                            SUPPORTED_EXTENSIONS.contains(&x.to_string_lossy().to_lowercase().as_str())
                        })
                        .unwrap_or(false)
            })
            .map(|e| e.path().to_path_buf())
            .collect();

        let total = audio_files.len();
        if total == 0 {
            let mut s = state.lock().unwrap();
            s.status_message = "No supported audio files found.".into();
            s.is_converting = false;
            return;
        }

        let target_kbps: f64 = bitrate.parse().unwrap_or(320.0);

        // Shared counters updated from rayon worker threads
        let completed    = Arc::new(Mutex::new(0usize));
        let transferred  = Arc::new(Mutex::new(0usize));
        let skipped      = Arc::new(Mutex::new(0usize));

        let state_ref   = Arc::clone(&state);
        let comp_ref    = Arc::clone(&completed);
        let trans_ref   = Arc::clone(&transferred);
        let skip_ref    = Arc::clone(&skipped);

        audio_files.par_iter().for_each(|file| {
            let ext = file
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            let stem = file
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            let output = destination.join(format!("{}.mp3", stem));

            let already_exists = output.exists();
            let was_skipped;

            if already_exists && !force_overwrite {
                // Default: never overwrite a file that's already on the device
                was_skipped = true;
            } else {
                was_skipped = false;

                if already_exists {
                    let _ = std::fs::remove_file(&output);
                }

                if ext == "mp3" {
                    // Only re-encode if the source is measurably higher bitrate
                    // than the target.  Otherwise just copy (same logic as Swift).
                    let estimated = estimate_bitrate(file);
                    if estimated > target_kbps + 15.0 {
                        run_ffmpeg(&ffmpeg, file, &output, &bitrate);
                    } else {
                        let _ = std::fs::copy(file, &output);
                    }
                } else {
                    run_ffmpeg(&ffmpeg, file, &output, &bitrate);
                }
            }

            // Update shared counters and push progress to the UI state.
            let c = {
                let mut v = comp_ref.lock().unwrap();
                *v += 1;
                *v
            };
            if was_skipped {
                *skip_ref.lock().unwrap() += 1;
            } else {
                *trans_ref.lock().unwrap() += 1;
            }
            let t  = *trans_ref.lock().unwrap();
            let sk = *skip_ref.lock().unwrap();

            let mut s = state_ref.lock().unwrap();
            s.progress = c as f64 / total as f64;
            s.status_message = format!(
                "Processed {} of {} ({} transferred, {} already on device)",
                c, total, t, sk
            );
        });

        let t  = *transferred.lock().unwrap();
        let sk = *skipped.lock().unwrap();

        let mut s = state.lock().unwrap();
        s.progress = 1.0;
        s.status_message = format!(
            "Done! {} transferred, {} already on device left untouched.",
            t, sk
        );
        s.is_converting = false;
        s.just_finished = true;
    });
}

// Helpers

fn run_ffmpeg(ffmpeg: &Path, input: &Path, output: &Path, bitrate: &str) {
    let _ = std::process::Command::new(ffmpeg)
        .args([
            "-y",
            "-i",
            &input.to_string_lossy(),
            "-map_metadata",
            "0",
            "-codec:a",
            "libmp3lame",
            "-b:a",
            &format!("{}k", bitrate),
            "-write_id3v1",
            "1",
            "-id3v2_version",
            "3",
            &output.to_string_lossy(),
        ])
        .output();
}

// Find bitrate (ffprobe or if fails, manual calc)
fn estimate_bitrate(path: &Path) -> f64 {
    if let Some(ffprobe) = find_tool("ffprobe") {
        let out = std::process::Command::new(ffprobe)
            .args([
                "-v",
                "quiet",
                "-show_entries",
                "format=bit_rate",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                &path.to_string_lossy(),
            ])
            .output();

        if let Ok(output) = out {
            if output.status.success() {
                let s = String::from_utf8_lossy(&output.stdout);
                if let Ok(bps) = s.trim().parse::<f64>() {
                    if bps > 0.0 {
                        return bps / 1000.0;
                    }
                }
            }
        }
    }

    // fallback
    let size_bytes = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let assumed_duration = 180.0_f64;
    (size_bytes as f64 * 8.0) / assumed_duration / 1000.0
}

/// Locates 'name' (e.g. '"ffmpeg"')
fn find_tool(name: &str) -> Option<PathBuf> {
    // Next to our own executable
    if let Ok(exe) = std::env::current_exe() {
        #[cfg(windows)]
        let candidate = exe.parent()?.join(format!("{}.exe", name));
        #[cfg(not(windows))]
        let candidate = exe.parent()?.join(name);

        if candidate.exists() {
            return Some(candidate);
        }
    }

    // Search PATH
    #[cfg(windows)]
    let finder = "where";
    #[cfg(not(windows))]
    let finder = "which";

    if let Ok(out) = std::process::Command::new(finder).arg(name).output() {
        if out.status.success() {
            if let Some(line) = String::from_utf8_lossy(&out.stdout).lines().next() {
                return Some(PathBuf::from(line.trim()));
            }
        }
    }

    None
}

pub fn format_bytes(bytes: u64) -> String {
    if bytes >= 1_000_000_000 {
        format!("{:.1} GB", bytes as f64 / 1_000_000_000.0)
    } else if bytes >= 1_000_000 {
        format!("{:.0} MB", bytes as f64 / 1_000_000.0)
    } else {
        format!("{:.0} KB", bytes as f64 / 1_000.0)
    }
}