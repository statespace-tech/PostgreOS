//! Command-line syntax for administration and SQL-accelerated recursive tools.

use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};

#[derive(Parser)]
#[command(name = "pgos", version, about = "Manage a PostgreOS filesystem")]
pub(crate) struct Cli {
    #[arg(
        long,
        env = "PGOS_DATABASE_URL",
        default_value = "postgresql:///pgos_dev",
        global = true
    )]
    pub database_url: String,
    #[arg(
        long,
        env = "PGOS_VOLUME",
        default_value = "development",
        global = true
    )]
    pub volume: String,
    /// Use the long-lived local daemon for supported file operations.
    #[arg(long, env = "PGOS_SOCKET", global = true)]
    pub socket: Option<PathBuf>,
    #[arg(long, env = "PGOS_DIAGNOSTICS", global = true)]
    pub diagnostics: bool,
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub(crate) enum Command {
    Init,
    Volume {
        #[command(subcommand)]
        command: VolumeCommand,
    },
    Sql {
        query: Option<String>,
    },
    Write {
        path: String,
        data: Option<String>,
    },
    /// Recursively load a local file or directory through `PostgreSQL` COPY.
    Import {
        source: PathBuf,
        destination: String,
    },
    Cp(CpArgs),
    Rm(RmArgs),
    Find(FindArgs),
    Grep(GrepArgs),
    Locate {
        pattern: String,
    },
    Du(DuArgs),
    Tools {
        #[command(subcommand)]
        command: ToolsCommand,
    },
}

#[derive(Subcommand)]
pub(crate) enum VolumeCommand {
    Create { name: String },
    List,
}

#[derive(Subcommand)]
pub(crate) enum ToolsCommand {
    Install { directory: PathBuf },
}

#[derive(Args)]
pub(crate) struct CpArgs {
    #[arg(short = 'r', short_alias = 'R', long, required = true)]
    pub recursive: bool,
    pub source: String,
    pub destination: String,
}

#[derive(Args)]
pub(crate) struct RmArgs {
    #[arg(short = 'r', short_alias = 'R', long)]
    pub recursive: bool,
    #[arg(short = 'f', long)]
    pub force: bool,
    #[arg(required = true)]
    pub paths: Vec<String>,
}

#[derive(Args)]
pub(crate) struct FindArgs {
    #[arg(default_value = "/")]
    pub path: String,
    #[arg(long = "name")]
    pub name: Option<String>,
    #[arg(long = "type", value_parser = ["f", "d", "l"])]
    pub kind: Option<String>,
}

#[derive(Args)]
// These independent booleans mirror GNU command-line flags, not domain state.
#[allow(clippy::struct_excessive_bools)]
pub(crate) struct GrepArgs {
    #[arg(short = 'F', long, conflicts_with = "extended_regexp")]
    pub fixed_strings: bool,
    #[arg(short = 'E', long)]
    pub extended_regexp: bool,
    #[arg(short = 'r', long)]
    pub recursive: bool,
    #[arg(long = "include")]
    pub includes: Vec<String>,
    #[arg(short = 'n', long)]
    pub line_number: bool,
    #[arg(short = 'w', long)]
    pub word_regexp: bool,
    pub pattern: String,
    #[arg(default_value = "/")]
    pub path: String,
}

#[derive(Args)]
pub(crate) struct DuArgs {
    #[arg(short = 's', long = "summarize")]
    pub summarize: bool,
    #[arg(default_value = "/")]
    pub path: String,
}
