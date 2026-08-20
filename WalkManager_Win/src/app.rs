use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use eframe::egui;

use crate::converter::{self, AudioTrackInfo, ConverterState};
use crate::device::{self, ConnectedDevice};
use crate::settings::DeviceSettingsStore;

// ──────────────────────────────────────────────────────────────────────────────
// Application state
// ──────────────────────────────────────────────────────────────────────────────

pub struct WalkManagerApp {
    // Device sidebar
    devices: Vec<ConnectedDevice>,
    selected_idx: Option<usize>,

    // Settings panel
    source_folder: Option<PathBuf>,
    selected_bitrate: String,

    // Conversion worker
    converter_state: Arc<Mutex<ConverterState>>,

    // Track list (populated by a background scan)
    tracks: Vec<AudioTrackInfo>,
    is_scanning: bool,
    scan_result: Arc<Mutex<Option<Vec<AudioTrackInfo>>>>,

    // Persistence
    settings_store: DeviceSettingsStore,

    // Timers
    last_device_scan: Instant,

    // UI transient state
    pending_delete_idx: Option<usize>,
    /// True while the user holds Ctrl (mirrors ⌥ Option on macOS).
    force_overwrite: bool,
    /// Non-empty once a conversion finishes; shown as a one-liner below the button.
    last_status: String,
}

const BITRATES: &[&str] = &["128", "192", "256", "320"];
const DEVICE_POLL_SECS: u64 = 2;

impl WalkManagerApp {
    pub fn new(_cc: &eframe::CreationContext) -> Self {
        let devices = device::enumerate_removable_drives();
        let settings_store = DeviceSettingsStore::load();
        let selected_idx = if devices.is_empty() { None } else { Some(0) };

        let mut app = Self {
            devices,
            selected_idx,
            source_folder: None,
            selected_bitrate: "320".into(),
            converter_state: Arc::new(Mutex::new(ConverterState::default())),
            tracks: Vec::new(),
            is_scanning: false,
            scan_result: Arc::new(Mutex::new(None)),
            settings_store,
            last_device_scan: Instant::now(),
            pending_delete_idx: None,
            force_overwrite: false,
            last_status: String::new(),
        };

        if let Some(i) = app.selected_idx {
            app.load_settings(i);
            app.trigger_scan(i);
        }

        app
    }

    // ── settings helpers ───────────────────────────────────────────────────

    fn load_settings(&mut self, idx: usize) {
        let key = self.devices[idx].identity_key();
        if let Some(s) = self.settings_store.settings_for(&key) {
            self.selected_bitrate = if s.bitrate.is_empty() {
                "320".into()
            } else {
                s.bitrate.clone()
            };
            if let Some(ref sf) = s.source_folder {
                self.source_folder = Some(PathBuf::from(sf));
            }
            let sub = s.music_subfolder.clone();
            let device = &mut self.devices[idx];
            if device.candidate_music_folders.contains(&sub) || sub.is_empty() {
                device.selected_music_folder = sub;
            }
        }
    }

    fn save_settings(&mut self, idx: usize) {
        let key = self.devices[idx].identity_key();
        let sub = self.devices[idx].selected_music_folder.clone();
        let sf = self
            .source_folder
            .as_ref()
            .map(|p| p.to_string_lossy().to_string());
        self.settings_store
            .save(&key, &self.selected_bitrate, &sub, sf.as_deref());
    }

    // ── background track scan ──────────────────────────────────────────────

    fn trigger_scan(&mut self, idx: usize) {
        self.is_scanning = true;
        let dest = self.devices[idx].effective_destination();
        let slot = Arc::clone(&self.scan_result);
        std::thread::spawn(move || {
            *slot.lock().unwrap() = Some(converter::scan_tracks(&dest));
        });
    }

    // ── formatting ─────────────────────────────────────────────────────────

    fn fmt_bytes(bytes: u64) -> String {
        converter::format_bytes(bytes)
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// eframe::App  (called every frame)
// ──────────────────────────────────────────────────────────────────────────────

impl eframe::App for WalkManagerApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        // ── poll background scan ───────────────────────────────────────────
        if self.is_scanning {
            if let Ok(mut slot) = self.scan_result.try_lock() {
                if let Some(tracks) = slot.take() {
                    self.tracks = tracks;
                    self.is_scanning = false;
                }
            }
        }

        // ── poll converter "just finished" signal ──────────────────────────
        {
            let mut cs = self.converter_state.lock().unwrap();
            if cs.just_finished {
                cs.just_finished = false;
                let msg = cs.status_message.clone();
                drop(cs);
                self.last_status = msg;
                if let Some(i) = self.selected_idx {
                    self.devices[i].refresh_capacity();
                    self.trigger_scan(i);
                }
            }
        }

        // ── periodic device list refresh ───────────────────────────────────
        if self.last_device_scan.elapsed() >= Duration::from_secs(DEVICE_POLL_SECS) {
            self.last_device_scan = Instant::now();
            let prev_id = self
                .selected_idx
                .and_then(|i| self.devices.get(i))
                .map(|d| d.id.clone());

            self.devices = device::enumerate_removable_drives();

            // Try to keep the same device selected after refresh
            self.selected_idx = prev_id
                .as_deref()
                .and_then(|id| self.devices.iter().position(|d| d.id == id))
                .or_else(|| {
                    if self.devices.is_empty() {
                        None
                    } else {
                        let i = 0;
                        self.load_settings(i);
                        self.trigger_scan(i);
                        Some(i)
                    }
                });
        }

        // ── Ctrl = force-overwrite mode (mirrors macOS ⌥ Option) ──────────
        ui.ctx().input(|i| self.force_overwrite = i.modifiers.ctrl);

        // ── layout ────────────────────────────────────────────────────────

        // LEFT SIDEBAR ──────────────────────────────────────────────────────
        egui::Panel::left("sidebar")
            .min_size(200.0)
            .max_size(240.0)
            .resizable(true)
            .show(ui, |ui| {
                ui.add_space(8.0);
                ui.label(egui::RichText::new("DEVICES").small().strong().color(
                    ui.visuals().weak_text_color(),
                ));
                ui.add_space(4.0);
                ui.separator();
                ui.add_space(4.0);

                if self.devices.is_empty() {
                    ui.label(
                        egui::RichText::new("No USB devices connected")
                            .color(ui.visuals().weak_text_color()),
                    );
                } else {
                    for (i, device) in self.devices.iter().enumerate() {
                        let selected = self.selected_idx == Some(i);
                        let label = format!("💾  {}", device.display_name());
                        if ui.selectable_label(selected, &label).clicked() && !selected {
                            self.selected_idx = Some(i);
                            self.load_settings(i);
                            self.trigger_scan(i);
                            self.last_status.clear();
                        }
                    }
                }
            });

        // MAIN PANEL ────────────────────────────────────────────────────────
        egui::CentralPanel::default().show(ui, |ui| {
            if let Some(idx) = self.selected_idx {
                // Borrowing workaround: pull values we need before mutable borrows.
                let display_name = self.devices[idx].display_name().to_string();
                let total = self.devices[idx].total_capacity;
                let used = self.devices[idx].used_capacity();
                let available = self.devices[idx].available_capacity;
                let used_frac = if total > 0 {
                    used as f32 / total as f32
                } else {
                    0.0
                };

                egui::ScrollArea::vertical().show(ui, |ui| {
                    ui.add_space(8.0);

                    // ── Device header card ─────────────────────────────────
                    egui::Frame::group(ui.style()).show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.label(egui::RichText::new("💾").size(38.0));
                            ui.add_space(8.0);
                            ui.vertical(|ui| {
                                ui.label(egui::RichText::new(&display_name).heading().strong());
                                ui.label(
                                    egui::RichText::new("USB Removable Drive")
                                        .color(ui.visuals().weak_text_color()),
                                );
                            });
                        });
                    });

                    ui.add_space(10.0);

                    // ── Storage bar ────────────────────────────────────────
                    egui::Frame::group(ui.style()).show(ui, |ui| {
                        let bar_h = 16.0;
                        let avail_w = ui.available_width() - ui.spacing().item_spacing.x * 2.0;

                        let (rect, _) = ui.allocate_exact_size(
                            egui::vec2(avail_w, bar_h),
                            egui::Sense::hover(),
                        );

                        // Background track
                        ui.painter().rect_filled(
                            rect,
                            4.0,
                            ui.visuals().extreme_bg_color,
                        );
                        // Used fill
                        let fill_w = (rect.width() * used_frac).max(if used > 0 { 4.0 } else { 0.0 });
                        ui.painter().rect_filled(
                            egui::Rect::from_min_size(rect.min, egui::vec2(fill_w, bar_h)),
                            4.0,
                            ui.visuals().hyperlink_color,
                        );

                        ui.add_space(4.0);
                        ui.horizontal(|ui| {
                            ui.label(
                                egui::RichText::new(format!("{} used", Self::fmt_bytes(used)))
                                    .color(ui.visuals().hyperlink_color)
                                    .small(),
                            );
                            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                ui.label(
                                    egui::RichText::new(format!("{} total", Self::fmt_bytes(total)))
                                        .color(ui.visuals().weak_text_color())
                                        .small(),
                                );
                                ui.label(
                                    egui::RichText::new(format!("  {}  free", Self::fmt_bytes(available)))
                                        .color(ui.visuals().weak_text_color())
                                        .small(),
                                );
                            });
                        });
                    });

                    ui.add_space(10.0);
                    ui.separator();
                    ui.add_space(6.0);

                    // ── Sync settings ──────────────────────────────────────
                    ui.label(egui::RichText::new("Sync Settings").strong());
                    ui.add_space(4.0);

                    egui::Frame::group(ui.style()).show(ui, |ui| {
                        // Source folder
                        ui.horizontal(|ui| {
                            ui.label("📁  Music Folder:");
                            let text = self
                                .source_folder
                                .as_ref()
                                .map(|p| p.display().to_string())
                                .unwrap_or_else(|| "Not selected".to_string());
                            ui.add(
                                egui::Label::new(
                                    egui::RichText::new(&text)
                                        .color(ui.visuals().weak_text_color()),
                                )
                                .truncate(),
                            );
                            if ui.button("Choose…").clicked() {
                                if let Some(path) = rfd::FileDialog::new().pick_folder() {
                                    self.source_folder = Some(path);
                                    self.save_settings(idx);
                                }
                            }
                        });

                        ui.add_space(4.0);

                        // Destination subfolder on device
                        ui.horizontal(|ui| {
                            ui.label("📥  Destination on Device:");
                            // We can't borrow self.devices[idx] mutably while
                            // self is borrowed for the closure, so clone first.
                            let candidates = self.devices[idx].candidate_music_folders.clone();
                            let mut sel = self.devices[idx].selected_music_folder.clone();

                            egui::ComboBox::new("dest_subfolder", "")
                                .selected_text(if sel.is_empty() { "Device Root" } else { &sel })
                                .show_ui(ui, |ui| {
                                    ui.selectable_value(&mut sel, String::new(), "Device Root");
                                    for folder in &candidates {
                                        ui.selectable_value(&mut sel, folder.clone(), folder);
                                    }
                                });

                            if sel != self.devices[idx].selected_music_folder {
                                self.devices[idx].selected_music_folder = sel;
                                self.save_settings(idx);
                                self.trigger_scan(idx);
                            }
                        });

                        ui.add_space(4.0);

                        // MP3 bitrate
                        ui.horizontal(|ui| {
                            ui.label("🎵  MP3 Export Quality:");
                            let mut br = self.selected_bitrate.clone();
                            egui::ComboBox::new("bitrate", "")
                                .selected_text(format!("{} kbps", &br))
                                .show_ui(ui, |ui| {
                                    for b in BITRATES {
                                        ui.selectable_value(
                                            &mut br,
                                            b.to_string(),
                                            format!("{} kbps", b),
                                        );
                                    }
                                });
                            if br != self.selected_bitrate {
                                self.selected_bitrate = br;
                                self.save_settings(idx);
                            }
                        });
                    });

                    ui.add_space(10.0);

                    // ── Convert / progress ─────────────────────────────────
                    {
                        let cs = self.converter_state.lock().unwrap();
                        let converting = cs.is_converting;
                        let progress = cs.progress as f32;
                        let status = cs.status_message.clone();
                        drop(cs);

                        if converting {
                            ui.add(
                                egui::ProgressBar::new(progress)
                                    .show_percentage()
                                    .animate(true),
                            );
                            ui.label(
                                egui::RichText::new(&status)
                                    .color(ui.visuals().weak_text_color()),
                            );
                        } else {
                            let btn_label = if self.force_overwrite {
                                format!("⟳  Overwrite & Transfer to {}", display_name)
                            } else {
                                format!("▶  Convert & Transfer to {}", display_name)
                            };

                            let can_start = self.source_folder.is_some();
                            ui.add_enabled_ui(can_start, |ui| {
                                if ui
                                    .add_sized(
                                        egui::vec2(ui.available_width(), 32.0),
                                        egui::Button::new(
                                            egui::RichText::new(&btn_label).strong(),
                                        ),
                                    )
                                    .clicked()
                                {
                                    if let Some(ref src) = self.source_folder.clone() {
                                        let dest = self.devices[idx].effective_destination();
                                        converter::start_conversion(
                                            src.clone(),
                                            dest,
                                            self.selected_bitrate.clone(),
                                            self.force_overwrite,
                                            Arc::clone(&self.converter_state),
                                        );
                                        self.last_status.clear();
                                    }
                                }
                            });

                            if !self.last_status.is_empty() {
                                ui.label(
                                    egui::RichText::new(&self.last_status)
                                        .color(ui.visuals().weak_text_color()),
                                );
                            }

                            let hint = if self.force_overwrite {
                                "Will delete and re-write all songs already on the device."
                            } else if self.source_folder.is_none() {
                                "Choose a source folder above to get started."
                            } else {
                                "Will only add new songs. Hold Ctrl while clicking to fully overwrite."
                            };
                            ui.label(
                                egui::RichText::new(hint)
                                    .small()
                                    .color(ui.visuals().weak_text_color()),
                            );
                        }
                    }

                    ui.add_space(10.0);
                    ui.separator();
                    ui.add_space(6.0);

                    // ── On-device track list ───────────────────────────────
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new("Songs on Device").strong());
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if ui.small_button("⟳").clicked() {
                                self.trigger_scan(idx);
                            }
                            if self.is_scanning {
                                ui.spinner();
                            } else {
                                ui.label(
                                    egui::RichText::new(format!("{} tracks", self.tracks.len()))
                                        .color(ui.visuals().weak_text_color()),
                                );
                            }
                        });
                    });
                    ui.add_space(4.0);

                    if self.tracks.is_empty() && !self.is_scanning {
                        ui.label(
                            egui::RichText::new("No audio files found on this device yet.")
                                .color(ui.visuals().weak_text_color()),
                        );
                    } else {
                        // Column header row
                        egui::Grid::new("track_header")
                            .num_columns(4)
                            .min_col_width(0.0)
                            .show(ui, |ui| {
                                ui.label(egui::RichText::new("Filename").strong());
                                ui.label(egui::RichText::new("Duration").strong());
                                ui.label(egui::RichText::new("Size").strong());
                                ui.label("");
                                ui.end_row();
                            });
                        ui.separator();

                        let mut delete_at: Option<usize> = None;

                        egui::ScrollArea::vertical()
                            .id_salt("track_scroll")
                            .max_height(280.0)
                            .show(ui, |ui| {
                                egui::Grid::new("track_grid")
                                    .num_columns(4)
                                    .striped(true)
                                    .min_col_width(0.0)
                                    .show(ui, |ui| {
                                        for (i, track) in self.tracks.iter().enumerate() {
                                            ui.label(&track.title);
                                            ui.label(
                                                egui::RichText::new(&track.duration_display)
                                                    .color(ui.visuals().weak_text_color()),
                                            );
                                            ui.label(
                                                egui::RichText::new(&track.size_display)
                                                    .color(ui.visuals().weak_text_color()),
                                            );
                                            if ui
                                                .small_button(
                                                    egui::RichText::new("🗑")
                                                        .color(egui::Color32::from_rgb(200, 60, 60)),
                                                )
                                                .on_hover_text("Delete from device")
                                                .clicked()
                                            {
                                                delete_at = Some(i);
                                            }
                                            ui.end_row();
                                        }
                                    });
                            });

                        if let Some(i) = delete_at {
                            self.pending_delete_idx = Some(i);
                        }
                    }
                }); // end ScrollArea
            } else {
                // No device selected
                ui.centered_and_justified(|ui| {
                    ui.vertical_centered(|ui| {
                        ui.add_space(80.0);
                        ui.label(egui::RichText::new("💾").size(48.0));
                        ui.add_space(8.0);
                        ui.label(egui::RichText::new("No Device Selected").heading());
                        ui.add_space(4.0);
                        ui.label(
                            egui::RichText::new(
                                "Plug in a USB flash drive or MP3 player\nand it will appear in the sidebar.",
                            )
                            .color(ui.visuals().weak_text_color()),
                        );
                    });
                });
            }
        });

        // ── Delete-confirmation modal ───────────────────────────────────────
        if let Some(del_idx) = self.pending_delete_idx {
            if del_idx < self.tracks.len() {
                let track_title = self.tracks[del_idx].title.clone();
                let file_path = self.tracks[del_idx].file_path.clone();
                let mut confirmed = false;
                let mut cancelled = false;

                egui::Window::new("Confirm Delete")
                    .collapsible(false)
                    .resizable(false)
                    .anchor(egui::Align2::CENTER_CENTER, egui::vec2(0.0, 0.0))
                    .show(ui.ctx(), |ui| {
                        ui.label(format!("Delete \"{}\" from device?", track_title));
                        ui.add_space(4.0);
                        ui.label(
                            egui::RichText::new(
                                "This permanently removes the file from the device.\n\
                                 It does not affect your source library.",
                            )
                            .color(ui.visuals().weak_text_color()),
                        );
                        ui.add_space(8.0);
                        ui.horizontal(|ui| {
                            if ui
                                .button(egui::RichText::new("Delete").color(
                                    egui::Color32::from_rgb(200, 60, 60),
                                ))
                                .clicked()
                            {
                                confirmed = true;
                            }
                            if ui.button("Cancel").clicked() {
                                cancelled = true;
                            }
                        });
                    });

                if confirmed {
                    let _ = std::fs::remove_file(&file_path);
                    self.tracks.remove(del_idx);
                    self.pending_delete_idx = None;
                    if let Some(i) = self.selected_idx {
                        self.devices[i].refresh_capacity();
                    }
                } else if cancelled {
                    self.pending_delete_idx = None;
                }
            } else {
                self.pending_delete_idx = None;
            }
        }

        // ── Keep repainting while work is in progress ──────────────────────
        let still_busy = self.is_scanning
            || self.converter_state.lock().unwrap().is_converting;
        if still_busy {
            ui.ctx().request_repaint_after(Duration::from_millis(120));
        }
    }
}