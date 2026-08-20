use std::path::PathBuf;

// A removable USB drive visible to the OS.
#[derive(Debug, Clone)]
pub struct ConnectedDevice {
    // Drive letter identifier, e.g. '"E:"'.  Stable for the current mount.
    pub id: String,
    // Root path of the mount, e.g. '"E:\\"'.
    pub mount_path: PathBuf,
    // Volume label reported by the device, e.g. '"WALKMAN"'.
    pub volume_name: String,
    pub total_capacity: u64,
    pub available_capacity: u64,
    // Top-level subdirectories that look like music destinations
    // (e.g. '"MUSIC"', '"Mp3"').  Empty vec = only root is offered.
    pub candidate_music_folders: Vec<String>,
    // Which of the above is currently selected.  Empty = device root.
    pub selected_music_folder: String,
}

impl ConnectedDevice {
    pub fn display_name(&self) -> &str {
        if self.volume_name.is_empty() {
            &self.id
        } else {
            &self.volume_name
        }
    }

    pub fn used_capacity(&self) -> u64 {
        self.total_capacity.saturating_sub(self.available_capacity)
    }

    // Actual filesystem path that transfers should write into.
    pub fn effective_destination(&self) -> PathBuf {
        if self.selected_music_folder.is_empty() {
            self.mount_path.clone()
        } else {
            self.mount_path.join(&self.selected_music_folder)
        }
    }

    // Stable key used to persist per-device settings.
    // Keyed on volume name + drive letter (best we can do for generic USB storage).
    pub fn identity_key(&self) -> String {
        format!("{}|{}", self.volume_name, self.id).to_lowercase()
    }

    // Re-reads capacity from the OS; call after a transfer or deletion.
    pub fn refresh_capacity(&mut self) {
        if let Some((total, available)) = disk_space(&self.mount_path) {
            self.total_capacity = total;
            self.available_capacity = available;
        }
    }
}

// Public entry point

// Returns all currently-mounted removable drives.
pub fn enumerate_removable_drives() -> Vec<ConnectedDevice> {
    #[cfg(windows)]
    return enumerate_windows();

    #[cfg(not(windows))]
    Vec::new()
}

// Windows implementation
// macOS implementation was done first directly with Swift

#[cfg(windows)]
const DRIVE_REMOVABLE: u32 = 2;
fn enumerate_windows() -> Vec<ConnectedDevice> {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    use windows_sys::Win32::Storage::FileSystem::{
        GetDriveTypeW, GetLogicalDrives, GetVolumeInformationW,
    };

    let mut devices = Vec::new();

    // GetLogicalDrives() returns a bitmask: bit 0 = A:, bit 1 = B:, …, bit 25 = Z:
    let mask = unsafe { GetLogicalDrives() };

    for bit in 0..26u32 {
        if mask & (1 << bit) == 0 {
            continue;
        }

        let letter = (b'A' + bit as u8) as char;
        let root_str = format!("{}:\\", letter);
        let root_wide: Vec<u16> = root_str.encode_utf16().chain(std::iter::once(0)).collect();

        // Skip anything that isn't DRIVE_REMOVABLE (flash drives, SD cards, …)
        let drive_type = unsafe { GetDriveTypeW(root_wide.as_ptr()) };
        if drive_type != DRIVE_REMOVABLE {
            continue;
        }

        // Retrieve the volume label
        let mut vol_name_buf = [0u16; 256];
        let mut fs_name_buf = [0u16; 256];
        let mut serial = 0u32;
        let mut max_comp = 0u32;
        let mut flags = 0u32;

        let ok = unsafe {
            GetVolumeInformationW(
                root_wide.as_ptr(),
                vol_name_buf.as_mut_ptr(),
                vol_name_buf.len() as u32,
                &mut serial,
                &mut max_comp,
                &mut flags,
                fs_name_buf.as_mut_ptr(),
                fs_name_buf.len() as u32,
            )
        };

        let volume_name = if ok != 0 {
            let len = vol_name_buf.iter().position(|&c| c == 0).unwrap_or(0);
            OsString::from_wide(&vol_name_buf[..len])
                .to_string_lossy()
                .into_owned()
        } else {
            String::new()
        };

        let mount_path = PathBuf::from(&root_str);
        let (total, available) = disk_space(&mount_path).unwrap_or((0, 0));
        let candidate_music_folders = scan_music_folders(&mount_path);
        let selected = candidate_music_folders.first().cloned().unwrap_or_default();

        devices.push(ConnectedDevice {
            id: format!("{}:", letter),
            mount_path,
            volume_name,
            total_capacity: total,
            available_capacity: available,
            candidate_music_folders,
            selected_music_folder: selected,
        });
    }

    devices
}

// Helpers

// Returns '(total_bytes, available_bytes)' for the given path, or 'None' on error.
fn disk_space(path: &PathBuf) -> Option<(u64, u64)> {
    #[cfg(windows)]
    {
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

        let wide: Vec<u16> = path
            .to_string_lossy()
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();

        let mut caller_free: u64 = 0;
        let mut total: u64 = 0;
        let mut total_free: u64 = 0;

        let ok = unsafe {
            GetDiskFreeSpaceExW(wide.as_ptr(), &mut caller_free, &mut total, &mut total_free)
        };

        if ok != 0 {
            return Some((total, caller_free));
        }
    }

    // Silence unused-variable warning on non-Windows
    let _ = path;
    None
}

// Finds top-level directories on 'root' whose names match conventional music
fn scan_music_folders(root: &PathBuf) -> Vec<String> {
    const HINTS: &[&str] = &["music", "mp3", "songs", "audio", "musik"];

    let mut found = Vec::new();
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                let name = entry.file_name().to_string_lossy().to_string();
                if HINTS.contains(&name.to_lowercase().as_str()) {
                    found.push(name);
                }
            }
        }
    }
    found.sort();
    found
}