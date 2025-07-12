mod config;
mod sniff;
mod guard;

use config::PacketGuardConfig;

fn main() {
    env_logger::init();
    let config = PacketGuardConfig::load("config.toml").expect("Failed to load config");

    match config.mode.as_str() {
        "sniff" => sniff::start_sniffer(config),
        "guard" => guard::start_guard(config),
        other => panic!("Unknown mode: {other}"),
    }
}