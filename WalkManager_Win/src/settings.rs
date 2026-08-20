use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

/// Settings remembered per device across sessions.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DeviceSyncSettings {
    pub bitrate: String,
    pub music_subfolder: String,
    /// Absolute path to the source music library folder.
    pub source_folder: Option<String>,
}

/// Persists a map of 'identity_key -> DeviceSyncSettings' as JSON.
///
/// On Windows the file lives at:
///   '%LOCALAPPDATA%\WalkManager\device_settings.json'
pub struct DeviceSettingsStore {
    path: PathBuf,
    cache: HashMap<String, DeviceSyncSettings>,
}

impl DeviceSettingsStore {
    /// Load from disk (or start empty if the file doesn't exist yet).
    pub fn load() -> Self {
        let path = settings_path();

        let cache: HashMap<String, DeviceSyncSettings> =
            std::fs::read_to_string(&path)
                .ok()
                .and_then(|data| serde_json::from_str(&data).ok())
                .unwrap_or_default();

        Self { path, cache }
    }

    pub fn settings_for(&self, key: &str) -> Option<&DeviceSyncSettings> {
        self.cache.get(key)
    }

    pub fn save(
        &mut self,
        key: &str,
        bitrate: &str,
        music_subfolder: &str,
        source_folder: Option<&str>,
    ) {
        self.cache.insert(
            key.to_string(),
            DeviceSyncSettings {
                bitrate: bitrate.to_string(),
                music_subfolder: music_subfolder.to_string(),
                source_folder: source_folder.map(str::to_string),
            },
        );
        self.persist();
    }

    fn persist(&self) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(&self.cache) {
            let _ = std::fs::write(&self.path, json);
        }
    }
}

fn settings_path() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("WalkManager")
        .join("device_settings.json")
}