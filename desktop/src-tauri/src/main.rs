#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    whalegirl_app_lib::install_diagnostics();
    whalegirl_app_lib::run();
}
