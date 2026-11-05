#![allow(unexpected_cfgs)]
mod core;
mod services;
mod ui;
mod update;
mod watcher;
use core::*;
use std::{
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
};
pub static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("NameGuard: {e}");
        std::process::exit(1);
    }
}
fn execute() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let option = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    if args.iter().any(|a| a == "--help") {
        println!("NameGuard {}\nnameguard --menu | --watch | --audit | --roots [--config PATH] [--state-dir PATH]",env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if args.iter().any(|a| a == "--version") {
        println!("{}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    unsafe {
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
    }
    let executable = std::env::current_exe()?;
    let directory = option("--state-dir")
        .map(PathBuf::from)
        .unwrap_or_else(|| services::default_directory(&executable, &home()));
    let config_path = option("--config")
        .map(PathBuf::from)
        .unwrap_or_else(|| directory.join("config.json"));
    if args.is_empty() || args.iter().any(|a| a == "--menu") {
        let health = option("--update-health")
            .filter(|_| option("--update-version").as_deref() == Some(env!("CARGO_PKG_VERSION")))
            .and_then(|p| update::health_receipt(std::path::Path::new(&p), &directory));
        return ui::run(executable, directory, config_path, health);
    }
    let config = Configuration::load(&config_path)?;
    if args.iter().any(|a| a == "--roots") {
        for root in config.discover() {
            println!("{}", root.display());
        }
    } else if args.iter().any(|a| a == "--watch") {
        watcher::Engine::new(config, directory)?
            .run(option("--parent-pid").map(|p| p.parse()).transpose()?)?;
    } else if args.iter().any(|a| a == "--audit") {
        if watcher::Engine::new(config, directory)?.audit()? != 0 {
            return Err(error("Scan errors"));
        }
    } else {
        return Err(error("Use --help, --menu, --audit, --roots, or --watch."));
    }
    Ok(())
}
