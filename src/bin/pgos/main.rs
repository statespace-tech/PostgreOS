//! `pgos` administration and recursive-command acceleration entry point.

mod args;
mod client;
mod commands;
mod multicall;

use std::process::ExitCode;

use anyhow::Result;
use clap::Parser;

use crate::args::Cli;

fn main() -> ExitCode {
    match run() {
        Ok(status) => status,
        Err(error) => {
            eprintln!("pgos: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<ExitCode> {
    let invocation = multicall::Invocation::from_environment()?;
    let cli = Cli::parse_from(&invocation.arguments);
    commands::run(cli, invocation.is_multicall)
}
