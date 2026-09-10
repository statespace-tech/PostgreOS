//! Differential contract tests. SQL and fallback coverage are reported separately.

#![cfg(target_os = "linux")]

use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    process::{Command, Stdio},
};

use postgreos::postgres::Database;
use tempfile::TempDir;
use uuid::Uuid;

fn file_outputs(bytes: &[u8]) -> BTreeMap<&[u8], Vec<&[u8]>> {
    let mut files: BTreeMap<&[u8], Vec<&[u8]>> = BTreeMap::new();
    for line in bytes.split_inclusive(|byte| *byte == b'\n') {
        let end = line
            .iter()
            .position(|byte| *byte == b':')
            .unwrap_or(line.len());
        files.entry(&line[..end]).or_default().push(line);
    }
    files
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "one table-driven test keeps all GNU argument cases under one fixture"
)]
fn gnu_grep_arguments_output_and_status() {
    let Ok(url) = std::env::var("PGOS_TEST_DATABASE_URL") else {
        eprintln!("SKIP GNU grep differential tests: PGOS_TEST_DATABASE_URL is unset");
        return;
    };
    let version = Command::new("/usr/bin/grep")
        .arg("--version")
        .output()
        .unwrap();
    assert!(String::from_utf8_lossy(&version.stdout).contains("GNU grep"));
    let database = Database::connect(&url).expect("configured test database must connect");
    database.migrate().unwrap();
    let volume_name = format!("grep-contract-{}", Uuid::new_v4());
    let volume = database.create_volume(&volume_name).unwrap();
    database.mkdir(volume, "/docs", true).unwrap();
    let root = TempDir::new().unwrap();
    let docs = root.path().join("docs");
    fs::create_dir(&docs).unwrap();
    for (name, contents) in [
        (
            "a.c",
            "PM_SUSPEND\nfoo_PM_SUSPEND\na+b\naaab\nabab\nmatch\r\n\nlast match",
        ),
        ("b.h", "PM_SUSPEND\nNO_MATCH\nαPM_SUSPEND\n"),
        ("c.txt", "PM_SUSPEND\n"),
        (".hidden", "PM_SUSPEND\n"),
        ("bom.c", "\u{feff}PM_SUSPEND\n"),
    ] {
        fs::write(docs.join(name), contents).unwrap();
        database
            .write(volume, &format!("/docs/{name}"), contents.as_bytes())
            .unwrap();
    }
    let binary = assert_cmd::cargo::cargo_bin!("pgos");
    let wrapper = root.path().join("grep");
    std::os::unix::fs::symlink(binary, &wrapper).unwrap();

    let cases: &[(&[&str], bool)] = &[
        (&["-r", "-n", "PM_SUSPEND"], true),
        (&["-r", "-n", "a+b"], true),
        (&["-r", "-n", "-E", "a+b"], true),
        (&["-r", "-n", "-F", "match"], true),
        (&["-r", "-n", "-F", ""], true),
        (&["-r", "-n", "-F", "absent"], true),
        (
            &[
                "-E",
                "-r",
                "-n",
                "--include=*.c",
                "--include=*.h",
                "-w",
                "[A-Z]+_SUSPEND",
            ],
            true,
        ),
        (&["-r", "-n", r"\(ab\)\1"], false),
        (&["-r", "-n", "["], false),
        (&["-r", "-i", "pm_suspend"], false),
        (&["-r", "-v", "PM_SUSPEND"], false),
        (&["-r", "-c", "PM_SUSPEND"], false),
        (&["-r", "-l", "PM_SUSPEND"], false),
        (&["-r", "-L", "PM_SUSPEND"], false),
        (&["-r", "-q", "PM_SUSPEND"], false),
        (&["-r", "-o", "PM_SUSPEND"], false),
        (&["-r", "-m", "1", "PM_SUSPEND"], false),
        (&["-r", "-e", "PM_SUSPEND", "-e", "match"], false),
        (&["-r", "--exclude=*.c", "PM_SUSPEND"], false),
        (&["-r", "--color=always", "PM_SUSPEND"], false),
        (&["-r", "-A", "1", "PM_SUSPEND"], false),
        (&["-r", "-B", "1", "PM_SUSPEND"], false),
        (&["-r", "-x", "PM_SUSPEND"], false),
        (&["-r", "-b", "PM_SUSPEND"], false),
        (&["-r", "-z", "PM_SUSPEND"], false),
        (&["-r", "-P", r"(?<=PM_)SUSPEND"], false),
        (&["--help"], false),
        (&["--version"], false),
    ];
    for (args, sql) in cases {
        let expected = Command::new("/usr/bin/grep")
            .env("LC_ALL", "C.UTF-8")
            .args(*args)
            .arg(&docs)
            .output()
            .unwrap();
        let actual = Command::new(&wrapper)
            .env("LC_ALL", "C.UTF-8")
            .env("PGOS_DATABASE_URL", &url)
            .env("PGOS_VOLUME", &volume_name)
            .env("PGOS_MOUNT", root.path())
            .env("PGOS_DIAGNOSTICS", "true")
            .env_remove("PGOS_SOCKET")
            .args(*args)
            .arg(&docs)
            .output()
            .unwrap();
        let diagnostic_end = actual
            .stderr
            .iter()
            .position(|byte| *byte == b'\n')
            .unwrap()
            + 1;
        let diagnostic = String::from_utf8_lossy(&actual.stderr[..diagnostic_end]);
        assert_eq!(
            diagnostic.contains("using direct SQL"),
            *sql,
            "wrong path: {args:?}: {diagnostic}"
        );
        assert_eq!(
            actual.status.code(),
            expected.status.code(),
            "exit status: {args:?}: {}",
            String::from_utf8_lossy(&actual.stderr)
        );
        assert_eq!(
            file_outputs(&actual.stdout),
            file_outputs(&expected.stdout),
            "stdout: {args:?}"
        );
        assert_eq!(
            &actual.stderr[diagnostic_end..],
            expected.stderr,
            "stderr: {args:?}"
        );
    }

    // A single file must not gain a filename prefix from the recursive SQL path.
    for locale in ["C", "C.UTF-8"] {
        let path = docs.join("b.h");
        let arguments = ["-r", "-n", "-w", "PM_SUSPEND"];
        let expected = Command::new("/usr/bin/grep")
            .env("LC_ALL", locale)
            .args(arguments)
            .arg(&path)
            .output()
            .unwrap();
        let actual = Command::new(&wrapper)
            .env("LC_ALL", locale)
            .env("PGOS_MOUNT", root.path())
            .env_remove("PGOS_DIAGNOSTICS")
            .args(arguments)
            .arg(&path)
            .output()
            .unwrap();
        assert_eq!(actual.stdout, expected.stdout);
        assert_eq!(actual.stderr, expected.stderr);
        assert_eq!(actual.status.code(), expected.status.code());
    }

    // Stdin, binary bytes and backreferences must reach GNU grep unchanged.
    for args in [vec!["-n", "match"], vec!["-a", "match"], vec![r"\(ab\)\1"]] {
        let run = |executable: &std::path::Path| {
            let mut child = Command::new(executable)
                .args(&args)
                .env("LC_ALL", "C.UTF-8")
                .env("PGOS_MOUNT", root.path())
                .env_remove("PGOS_DIAGNOSTICS")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            child
                .stdin
                .take()
                .unwrap()
                .write_all(b"match\0bytes\nabab\nlast match")
                .unwrap();
            child.wait_with_output().unwrap()
        };
        let expected = run(std::path::Path::new("/usr/bin/grep"));
        let actual = run(&wrapper);
        assert_eq!(actual.stdout, expected.stdout);
        assert_eq!(actual.stderr, expected.stderr);
        assert_eq!(actual.status.code(), expected.status.code());
    }
}

#[test]
fn streamed_gnu_patterns_preserve_unicode_and_block_boundaries() {
    let Ok(url) = std::env::var("PGOS_TEST_DATABASE_URL") else {
        return;
    };
    let database = Database::connect(&url).unwrap();
    database.migrate().unwrap();
    let name = format!("grep-stream-{}", Uuid::new_v4());
    let volume = database.create_volume(&name).unwrap();
    let root = TempDir::new().unwrap();
    let path = root.path().join("text");
    let text = format!(
        "{}Sherlock Holmes",
        "Mr Sherlock Holmes\r\ntest@Sherlock Holmes\nSherlock Émile\nSherlock Aαβ\nSherlock A\u{301}B\nno match\n"
            .repeat(5000)
    );
    fs::write(&path, &text).unwrap();
    database
        .import_text(volume, "/text", std::io::Cursor::new(text.as_bytes()))
        .unwrap();
    let wrapper = root.path().join("grep");
    std::os::unix::fs::symlink(assert_cmd::cargo::cargo_bin!("pgos"), &wrapper).unwrap();
    for pattern in [
        r"Sherlock [A-Z]\w+",
        r"[A-Z]\w+ Sherlock [A-Z]\w+",
        r"Sherlock \W+",
        r"Sherlock \w+",
        "absent",
    ] {
        let expected = Command::new("/usr/bin/grep")
            .env("LC_ALL", "C.UTF-8")
            .args(["-E", "-w", pattern])
            .arg(&path)
            .output()
            .unwrap();
        let actual = Command::new(&wrapper)
            .env("LC_ALL", "C.UTF-8")
            .env("PGOS_DATABASE_URL", &url)
            .env("PGOS_VOLUME", &name)
            .env("PGOS_MOUNT", root.path())
            .env("PGOS_DIAGNOSTICS", "true")
            .env_remove("PGOS_SOCKET")
            .args(["-E", "-w", pattern])
            .arg(&path)
            .output()
            .unwrap();
        assert_eq!(
            actual.status.code(),
            expected.status.code(),
            "{pattern}: {:?}",
            actual.stderr
        );
        assert_eq!(actual.stdout, expected.stdout, "{pattern}");
        let error = String::from_utf8_lossy(&actual.stderr);
        assert!(error.contains("using direct SQL"), "{error}");
        assert_eq!(error.lines().count(), 1, "{error}");
    }
}
