//! Command dispatch and the `psql` escape hatch.

mod files;
mod search;

use std::process::Command as ProcessCommand;
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use postgreos::postgres::Database;

use crate::args::{Cli, Command, ToolsCommand, VolumeCommand};
use crate::client::FileClient;
use crate::multicall;

pub(crate) fn run(cli: Cli, multicall_mode: bool) -> Result<ExitCode> {
    if let Command::Sql { query } = &cli.command {
        run_psql(&cli.database_url, &cli.volume, query.as_deref())?;
        return Ok(ExitCode::SUCCESS);
    }
    if let Command::Tools { command } = &cli.command {
        match command {
            ToolsCommand::Install { directory } => multicall::install_tools(directory)?,
        }
        return Ok(ExitCode::SUCCESS);
    }

    if matches!(cli.command, Command::Init) {
        let database = Database::connect(&cli.database_url)?;
        database.migrate()?;
        println!("PostgreOS schema installed");
        return Ok(ExitCode::SUCCESS);
    }
    if let Command::Volume { command } = &cli.command {
        let database = Database::connect(&cli.database_url)?;
        match command {
            VolumeCommand::Create { name } => println!("{}", database.create_volume(name)?),
            VolumeCommand::List => {
                for (id, name) in database.volumes()? {
                    println!("{id}\t{name}");
                }
            }
        }
        return Ok(ExitCode::SUCCESS);
    }

    if is_daemon_capable(&cli.command) {
        return run_file_command(cli, multicall_mode);
    }

    let database = Database::connect(&cli.database_url)?;
    let volume = database.resolve_volume(&cli.volume)?;
    if cli.diagnostics {
        eprintln!("pgos: using direct SQL acceleration for volume {volume}");
    }
    match cli.command {
        Command::Write { path, data } => {
            files::write(&database, volume, &path, data, multicall_mode)?;
        }
        Command::Import {
            source,
            destination,
        } => files::import(&database, volume, &source, &destination)?,
        Command::Cp(_)
        | Command::Rm(_)
        | Command::Find(_)
        | Command::Locate { .. }
        | Command::Grep(_)
        | Command::Du(_)
        | Command::Init
        | Command::Volume { .. }
        | Command::Sql { .. }
        | Command::Tools { .. } => {
            unreachable!()
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn is_daemon_capable(command: &Command) -> bool {
    matches!(
        command,
        Command::Cp(_)
            | Command::Rm(_)
            | Command::Find(_)
            | Command::Locate { .. }
            | Command::Grep(_)
            | Command::Du(_)
    )
}

fn run_file_command(cli: Cli, multicall_mode: bool) -> Result<ExitCode> {
    let client = FileClient::connect(cli.socket.as_deref(), &cli.database_url, &cli.volume)?;
    if cli.diagnostics {
        eprintln!("pgos: using {} acceleration", client.description());
    }
    match cli.command {
        Command::Cp(options) => files::copy(&client, &options, multicall_mode)?,
        Command::Rm(options) => files::remove(&client, &options, multicall_mode)?,
        Command::Find(options) => search::find(&client, &options, multicall_mode)?,
        Command::Locate { pattern } => search::locate(&client, &pattern, multicall_mode)?,
        Command::Grep(options) => {
            return Ok(if search::grep(&client, &options, multicall_mode)? {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(1)
            });
        }
        Command::Du(options) => search::du(&client, &options, multicall_mode)?,
        _ => unreachable!(),
    }
    Ok(ExitCode::SUCCESS)
}

fn run_psql(url: &str, volume: &str, query: Option<&str>) -> Result<()> {
    let database = Database::connect(url)?;
    let volume = database.resolve_volume(volume)?;
    let mut command = ProcessCommand::new("psql");
    // The session setting lets UUID-free functions such as `pgos.list('/')`
    // operate on the volume selected by the CLI.
    command
        .env("PGOPTIONS", format!("-c pgos.volume_id={volume}"))
        .arg(url);
    if let Some(query) = query {
        command.arg("--command").arg(query);
    }
    let status = command.status().context("could not start psql")?;
    if !status.success() {
        bail!("psql exited with {status}");
    }
    Ok(())
}
