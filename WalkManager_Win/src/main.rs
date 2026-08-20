mod app;
mod converter;
mod device;
mod settings;

fn main() -> eframe::Result<()> {
    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([900.0, 580.0])
            .with_min_inner_size([760.0, 520.0])
            .with_title("WalkManager"),
        ..Default::default()
    };

    eframe::run_native(
        "WalkManager",
        native_options,
        Box::new(|cc| Ok(Box::new(app::WalkManagerApp::new(cc)))),
    )
}