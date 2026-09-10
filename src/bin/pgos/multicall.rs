//! Compatibility layer for SQL-accelerated recursive command links.

use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command as ProcessCommand;

use anyhow::{Context, Result, bail};
use clap::Parser;

use crate::args::{Cli, Command};

pub(crate) const TOOL_NAMES: &[&str] = &["du", "find", "locate", "grep", "cp", "rm"];

pub(crate) struct Invocation {
    pub arguments: Vec<OsString>,
    pub is_multicall: bool,
}

impl Invocation {
    pub fn from_environment() -> Result<Self> {
        let arguments: Vec<OsString> = env::args_os().collect();
        let command = arguments
            .first()
            .and_then(|argument| Path::new(argument).file_name())
            .and_then(|argument| argument.to_str());
        if let Some(command) = command.filter(|name| TOOL_NAMES.contains(name)) {
            let mut rewritten = vec![OsString::from("pgos"), OsString::from(command)];
            rewritten.extend(translate_arguments(command, &arguments[1..]));
            let supported = Cli::try_parse_from(&rewritten)
                .is_ok_and(|cli| command_paths_are_mounted(&cli.command));
            // Fall back before opening PostgreSQL. An unsupported invocation
            // must retain the behavior of the installed Debian command.
            if !supported {
                run_reference(command, &arguments[1..])?;
                unreachable!("reference command returned after successful exec");
            }
            Ok(Self {
                arguments: rewritten,
                is_multicall: true,
            })
        } else {
            Ok(Self {
                arguments,
                is_multicall: false,
            })
        }
    }
}

fn translate_arguments(command: &str, arguments: &[OsString]) -> Vec<OsString> {
    if command != "find" {
        return arguments.to_vec();
    }
    // `find` uses single-dash predicates. Clap reserves those spellings for
    // short flags, so translate only the predicates that PostgreOS supports.
    arguments
        .iter()
        .map(|argument| match argument.to_str() {
            Some("-name") => OsString::from("--name"),
            Some("-type") => OsString::from("--type"),
            _ => argument.clone(),
        })
        .collect()
}

fn command_paths_are_mounted(command: &Command) -> bool {
    let mount = env::var("PGOS_MOUNT").unwrap_or_else(|_| "/data".to_owned());
    let under_mount = |path: &str| Path::new(path).starts_with(&mount);
    match command {
        // Only recursive removal benefits from a set-based database operation.
        Command::Cp(options) => {
            options.recursive && under_mount(&options.source) && under_mount(&options.destination)
        }
        Command::Rm(options) => {
            options.recursive && options.paths.iter().all(|path| under_mount(path))
        }
        Command::Find(options) => under_mount(&options.path),
        Command::Du(options) => options.summarize && under_mount(&options.path),
        Command::Grep(options) => {
            under_mount(&options.path)
                // GNU grep omits the filename for a single explicit file,
                // even with -r. That invocation uses the reference path.
                && ((options.recursive && Path::new(&options.path).is_dir())
                    || (!options.recursive && Path::new(&options.path).is_file() && options.includes.is_empty()))
                && (!options.word_regexp || unicode_word_locale())
                && postgreos::core::search::include_suffixes(&options.includes).is_some()
                && ((!options.recursive && !options.line_number && options.includes.is_empty()
                    && postgreos::core::search::gnu_required_literals(&options.pattern, options.fixed_strings, options.extended_regexp).is_some()) || postgreos::core::search::gnu_pattern(
                    &options.pattern,
                    options.fixed_strings,
                    options.extended_regexp,
                    options.word_regexp,
                )
                .is_some())
        }
        Command::Locate { .. } => true,
        // Administrative commands are not installed as standard-name tools.
        _ => false,
    }
}

fn unicode_word_locale() -> bool {
    let locale = ["LC_ALL", "LC_CTYPE", "LANG"]
        .into_iter()
        .filter_map(|key| env::var(key).ok())
        .find(|value| !value.is_empty());
    // Rust's Unicode word boundaries do not implement the byte-oriented C
    // locale. Other locales need their own differential coverage first.
    matches!(locale.as_deref(), Some("C.UTF-8" | "C.utf8"))
}

#[cfg(unix)]
fn run_reference(command: &str, arguments: &[OsString]) -> Result<()> {
    use std::os::unix::process::CommandExt as _;

    let executable = reference_executable(command)?;
    if env::var_os("PGOS_DIAGNOSTICS").is_some() {
        eprintln!("pgos: falling back to {}", executable.display());
    }
    let error = ProcessCommand::new(executable).args(arguments).exec();
    Err(error).context("could not execute the reference command")
}

#[cfg(not(unix))]
fn run_reference(command: &str, arguments: &[OsString]) -> Result<()> {
    let executable = reference_executable(command)?;
    let status = ProcessCommand::new(executable).args(arguments).status()?;
    std::process::exit(status.code().unwrap_or(1));
}

fn reference_executable(command: &str) -> Result<PathBuf> {
    if let Some(directory) = env::var_os("PGOS_REFERENCE_BIN_DIR") {
        let path = PathBuf::from(directory).join(command);
        if path.is_file() {
            return Ok(path);
        }
    }
    for directory in ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
        let path = Path::new(directory).join(command);
        if path.is_file() && path != env::current_exe()? {
            return Ok(path);
        }
    }
    bail!("reference command {command:?} was not found")
}

pub(crate) fn map_path(input: &str, multicall: bool) -> Result<String> {
    if !multicall {
        return Ok(postgreos::core::path::normalize(input)?);
    }
    let mount = env::var("PGOS_MOUNT").unwrap_or_else(|_| "/data".to_owned());
    let input = Path::new(input);
    let mount = Path::new(&mount);
    // The database stores paths relative to a volume root. Standard commands
    // receive paths below the host mount and must remove that prefix.
    let relative = input.strip_prefix(mount).with_context(|| {
        format!(
            "path {} is outside PostgreOS mount {}",
            input.display(),
            mount.display()
        )
    })?;
    let relative = relative
        .to_str()
        .context("the prototype supports UTF-8 paths only")?;
    Ok(postgreos::core::path::normalize(&format!("/{relative}"))?)
}

pub(crate) fn display_path(path: &str, multicall: bool) -> String {
    format!("{}{}", display_prefix(multicall), path)
}

pub(crate) fn display_prefix(multicall: bool) -> String {
    if multicall {
        env::var("PGOS_MOUNT")
            .unwrap_or_else(|_| "/data".to_owned())
            .trim_end_matches('/')
            .to_owned()
    } else {
        String::new()
    }
}

pub(crate) fn install_tools(directory: &Path) -> Result<()> {
    std::fs::create_dir_all(directory)?;
    let executable = env::current_exe()?;
    for name in TOOL_NAMES {
        let destination = directory.join(name);
        if destination.exists() || destination.symlink_metadata().is_ok() {
            bail!("refusing to replace {}", destination.display());
        }
        install_link(&executable, &destination)?;
    }
    println!("installed PostgreOS tool links in {}", directory.display());
    Ok(())
}

#[cfg(unix)]
fn install_link(executable: &Path, destination: &PathBuf) -> Result<()> {
    std::os::unix::fs::symlink(executable, destination)?;
    Ok(())
}

#[cfg(not(unix))]
fn install_link(executable: &Path, destination: &PathBuf) -> Result<()> {
    std::fs::copy(executable, destination)?;
    Ok(())
}
