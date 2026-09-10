//! Metadata and content search commands.

use std::io::{self, Write};

use anyhow::{Context, Result};
use globset::Glob;

use crate::args::{DuArgs, FindArgs, GrepArgs};
use crate::client::FileClient;
use crate::multicall::{display_path, display_prefix, map_path};

pub(super) fn find(client: &FileClient, options: &FindArgs, multicall: bool) -> Result<()> {
    let root = map_path(&options.path, multicall)?;
    let wanted_kind = options.kind.as_deref().map(|kind| match kind {
        "f" => 1,
        "d" => 2,
        "l" => 3,
        _ => unreachable!(),
    });
    if options
        .name
        .as_deref()
        .is_some_and(|pattern| pattern.contains(['[', ']']))
    {
        let matcher = options
            .name
            .as_deref()
            .map(Glob::new)
            .transpose()
            .context("invalid name pattern")?
            .map(|glob| glob.compile_matcher());
        let paths = client
            .walk(&root)?
            .into_iter()
            .filter(|entry| {
                matcher
                    .as_ref()
                    .is_none_or(|matcher| matcher.is_match(&entry.name))
                    && wanted_kind.is_none_or(|kind| entry.kind == kind)
            })
            .map(|entry| entry.path)
            .collect::<Vec<_>>();
        for path in paths {
            println!("{}", display_path(&path, multicall));
        }
    } else {
        io::stdout().lock().write_all(&client.find_output(
            &root,
            options.name.as_deref(),
            wanted_kind,
            &display_prefix(multicall),
        )?)?;
    }
    Ok(())
}

pub(super) fn grep(client: &FileClient, options: &GrepArgs, multicall: bool) -> Result<bool> {
    let root = map_path(&options.path, multicall)?;
    let pattern = postgreos::core::search::gnu_pattern(
        &options.pattern,
        options.fixed_strings,
        options.extended_regexp,
        options.word_regexp,
    );
    if !options.recursive && !options.line_number && options.includes.is_empty() {
        return grep_text_stream(client, &root, options);
    }
    let pattern = pattern.context("pattern requires GNU grep on the mounted filesystem")?;
    if !options.recursive {
        return client.grep_file(
            &root,
            &pattern,
            options.line_number,
            &mut io::stdout().lock(),
        );
    }
    // SQL narrows the candidate set. The Rust matcher verifies only the
    // syntax subset checked above; unsupported GNU syntax uses the mount.
    let suffixes = postgreos::core::search::include_suffixes(&options.includes)
        .context("include pattern requires GNU grep on the mounted filesystem")?;
    client
        .grep_regex_output(
            &root,
            &pattern,
            options.line_number,
            &display_prefix(multicall),
            &suffixes,
            &mut io::stdout().lock(),
        )
        .context("invalid regular expression")
}

fn grep_text_stream(client: &FileClient, path: &str, options: &GrepArgs) -> Result<bool> {
    use std::process::{Command, Stdio};
    // Keep GNU's locale and regex semantics for syntax outside the Rust path.
    // SQL supplies line-aligned candidates through a pipe, never temporary files.
    let mut command = Command::new("/usr/bin/grep");
    if options.fixed_strings {
        command.arg("-F");
    }
    if options.extended_regexp {
        command.arg("-E");
    }
    if options.word_regexp {
        command.arg("-w");
    }
    let mut child = command
        .arg("--")
        .arg(&options.pattern)
        .stdin(Stdio::piped())
        .spawn()?;
    let literals = postgreos::core::search::gnu_required_literals(
        &options.pattern,
        options.fixed_strings,
        options.extended_regexp,
    );
    let word = literals.as_deref().and_then(|values| {
        postgreos::core::search::required_word(&options.pattern, values, options.word_regexp)
    });
    let minimum_ascii_letters = postgreos::core::search::minimum_ascii_letter_run(
        &options.pattern,
        options.fixed_strings,
        options.extended_regexp,
    );
    let result = client.text_stream(
        path,
        literals,
        word,
        minimum_ascii_letters,
        &mut child.stdin.take().context("missing grep input pipe")?,
    );
    if result.is_err() {
        let _ = child.kill();
    }
    let status = child.wait()?;
    result?;
    match status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => anyhow::bail!("GNU grep stream matcher failed: {status}"),
    }
}

pub(super) fn locate(client: &FileClient, pattern: &str, multicall: bool) -> Result<()> {
    for entry in client.walk("/")? {
        if entry.path.contains(pattern) {
            println!("{}", display_path(&entry.path, multicall));
        }
    }
    Ok(())
}

pub(super) fn du(client: &FileClient, options: &DuArgs, multicall: bool) -> Result<()> {
    let path = map_path(&options.path, multicall)?;
    let total = client.disk_usage(&path)?;
    println!("{total}\t{}", display_path(&path, multicall));
    Ok(())
}
