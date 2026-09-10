//! File-operation transport selected by CLI configuration.

use std::path::Path;

use anyhow::Result;
use postgreos::client::Client;
use postgreos::core::Entry;
use postgreos::postgres::Database;
use uuid::Uuid;

pub(crate) enum FileClient {
    Daemon(Client),
    Direct { database: Database, volume: Uuid },
}

impl FileClient {
    pub fn text_stream(
        &self,
        path: &str,
        literals: Option<Vec<String>>,
        word: Option<String>,
        minimum_ascii_letters: Option<u32>,
        output: &mut impl std::io::Write,
    ) -> Result<()> {
        match self {
            Self::Daemon(client) => {
                Ok(client.text_stream(path, literals, word, minimum_ascii_letters, output)?)
            }
            Self::Direct { database, volume } => database.candidate_word_text(
                *volume,
                path,
                literals.as_deref(),
                word.as_deref(),
                minimum_ascii_letters,
                |data| {
                    output.write_all(data)?;
                    Ok(())
                },
            ),
        }
    }

    pub fn grep_file(
        &self,
        path: &str,
        pattern: &str,
        line_number: bool,
        output: &mut impl std::io::Write,
    ) -> Result<bool> {
        match self {
            Self::Daemon(client) => Ok(client.grep_file(path, pattern, line_number, output)?),
            Self::Direct { database, volume } => {
                database.grep_file(*volume, path, pattern, line_number, |data| {
                    output.write_all(data)?;
                    Ok(())
                })
            }
        }
    }

    pub fn connect(socket: Option<&Path>, database_url: &str, volume: &str) -> Result<Self> {
        if let Some(socket) = socket {
            return Ok(Self::Daemon(Client::connect(socket, volume)?));
        }
        let database = Database::connect(database_url)?;
        let volume = database.resolve_volume(volume)?;
        Ok(Self::Direct { database, volume })
    }

    pub fn description(&self) -> &'static str {
        match self {
            Self::Daemon(_) => "pgosd",
            Self::Direct { .. } => "direct SQL",
        }
    }

    pub fn walk(&self, path: &str) -> Result<Vec<Entry>> {
        Ok(match self {
            Self::Daemon(client) => client.walk(path)?,
            Self::Direct { database, volume } => database.walk(*volume, path)?,
        })
    }

    pub fn find_output(
        &self,
        root: &str,
        name_pattern: Option<&str>,
        kind: Option<i16>,
        path_prefix: &str,
    ) -> Result<Vec<u8>> {
        Ok(match self {
            Self::Daemon(client) => client.find_output(root, name_pattern, kind, path_prefix)?,
            Self::Direct { database, volume } => database
                .find_paths(*volume, root, name_pattern, kind)?
                .into_iter()
                .flat_map(|path| format!("{path_prefix}{path}\n").into_bytes())
                .collect(),
        })
    }

    pub fn disk_usage(&self, path: &str) -> Result<i64> {
        Ok(match self {
            Self::Daemon(client) => client.disk_usage(path)?,
            Self::Direct { database, volume } => database.disk_usage(*volume, path)?,
        })
    }

    pub fn grep_regex_output(
        &self,
        root: &str,
        pattern: &str,
        line_number: bool,
        path_prefix: &str,
        file_suffixes: &[String],
        output: &mut impl std::io::Write,
    ) -> Result<bool> {
        Ok(match self {
            Self::Daemon(client) => client.grep_regex_output(
                root,
                pattern,
                line_number,
                path_prefix,
                file_suffixes,
                output,
            )?,
            Self::Direct { database, volume } => {
                let literals = postgreos::core::search::required_literals(pattern);
                let mut matcher = postgreos::core::search::BlockMatcher::new(pattern, line_number)?;
                let mut found_any = false;
                let mut consume = |path: &str, first_line: i64, body: &str| {
                    let prefix = format!("{path_prefix}{path}:");
                    let (block_output, found) =
                        matcher.search_prefixed(first_line, body, prefix.as_bytes())?;
                    output.write_all(&block_output)?;
                    found_any |= found;
                    Ok(())
                };
                database.candidate_blocks(
                    *volume,
                    root,
                    literals.as_deref(),
                    file_suffixes,
                    &mut consume,
                )?;
                found_any
            }
        })
    }

    pub fn copy(&self, source: &str, destination: &str, recursive: bool) -> Result<i64> {
        Ok(match self {
            Self::Daemon(client) => client.copy(source, destination, recursive)?,
            Self::Direct { database, volume } => {
                database.copy(*volume, source, destination, recursive)?
            }
        })
    }

    pub fn remove_many(&self, paths: &[String], recursive: bool, force: bool) -> Result<i64> {
        Ok(match self {
            Self::Daemon(client) => client.remove_many(paths, recursive, force)?,
            Self::Direct { database, volume } => {
                database.remove_many(*volume, paths, recursive, force)?
            }
        })
    }
}
