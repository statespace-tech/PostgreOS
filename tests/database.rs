use anyhow::anyhow;
use postgreos::postgres::{Database, ImportEntry};
use uuid::Uuid;

fn test_database() -> Option<Database> {
    let url = std::env::var("PGOS_TEST_DATABASE_URL").ok()?;
    Database::connect(&url).ok()
}

#[test]
fn metadata_mutations_return_current_entries() {
    let Some(database) = test_database() else {
        return;
    };
    database.migrate().unwrap();
    let volume = database
        .create_volume(&format!("metadata-{}", Uuid::new_v4()))
        .unwrap();

    let directory = database.mkdir_entry(volume, "/directory", false).unwrap();
    assert_eq!(directory.path, "/directory");
    assert_eq!(directory.kind, 2);

    let file = database
        .write_entry(volume, "/directory/file", b"hello")
        .unwrap();
    assert_eq!(file.path, "/directory/file");
    assert_eq!(file.size, 5);

    let touched = database
        .set_times(
            volume,
            "/directory/file",
            1_700_000_000,
            0,
            1_700_000_123,
            0,
        )
        .unwrap();
    assert_eq!(touched.atime_seconds, 1_700_000_000);
    assert_eq!(touched.mtime_seconds, 1_700_000_123);
    assert!(touched.generation > file.generation);

    database.remove_volume(volume).unwrap();
}

fn sql_scalar(query: &str) -> String {
    let url = std::env::var("PGOS_TEST_DATABASE_URL").unwrap();
    let output = std::process::Command::new("psql")
        .args([&url, "-Atc", query])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

#[test]
fn block_storage_preserves_contents_copy_overwrite_and_rollback() {
    let Some(database) = test_database() else {
        return;
    };
    database.migrate().unwrap();
    let volume = database
        .create_volume(&format!("blocks-{}", Uuid::new_v4()))
        .unwrap();
    let text = format!("α{}last match", "match\r\nmiss\n".repeat(50_000));
    database
        .import_text(volume, "/large", std::io::Cursor::new(text.as_bytes()))
        .unwrap();
    assert_eq!(database.read(volume, "/large").unwrap(), text.as_bytes());
    let mut joined = String::new();
    let mut expected_line = 1;
    database
        .text_blocks(volume, "/large", |line, block| {
            assert_eq!(line, expected_line);
            expected_line +=
                i64::try_from(block.bytes().filter(|byte| *byte == b'\n').count()).unwrap();
            joined.push_str(block);
            Ok(())
        })
        .unwrap();
    assert_eq!(joined, text);
    for offset in [0_usize, 262_140, text.len() - 4, text.len(), text.len() + 1] {
        let start = offset.min(text.len());
        let end = (start + 512).min(text.len());
        assert_eq!(
            database
                .read_range(volume, "/large", offset as u64, 512)
                .unwrap(),
            text.as_bytes()[start..end]
        );
    }
    database.copy(volume, "/large", "/copy", false).unwrap();
    database.write(volume, "/large", b"replacement").unwrap();
    assert_eq!(database.read(volume, "/copy").unwrap(), text.as_bytes());
    assert_eq!(database.read(volume, "/large").unwrap(), b"replacement");
    assert!(
        database
            .import_text(volume, "/copy", std::io::Cursor::new(b"bad\0text"))
            .is_err()
    );
    assert_eq!(database.read(volume, "/copy").unwrap(), text.as_bytes());
    let mut output = Vec::new();
    assert!(
        database
            .grep_file(volume, "/copy", "match", true, |data| {
                output.extend_from_slice(data);
                Ok(())
            })
            .unwrap()
    );
    assert!(output.ends_with(b"100001:last match\n"));
    assert!(
        database
            .text_blocks(volume, "/missing", |_, _| Ok(()))
            .is_err()
    );
    database.mkdir(volume, "/directory", false).unwrap();
    database
        .import_text(
            volume,
            "/directory/file",
            std::io::Cursor::new(text.as_bytes()),
        )
        .unwrap();
    database
        .copy(volume, "/directory", "/copied-directory", true)
        .unwrap();
    assert_eq!(
        database.read(volume, "/copied-directory/file").unwrap(),
        text.as_bytes()
    );
    let mut candidates = Vec::new();
    database
        .candidate_text(volume, "/copy", Some(&["last match".into()]), |data| {
            candidates.extend_from_slice(data);
            Ok(())
        })
        .unwrap();
    assert_eq!(candidates, b"last match\n");
    assert!(
        database
            .search_literal_files(volume, "/copy", "match")
            .is_err()
    );
}

#[test]
fn sql_escape_hatch_round_trip() {
    let Some(database) = test_database() else {
        eprintln!("skipping: PGOS_TEST_DATABASE_URL is not set");
        return;
    };
    database.migrate().unwrap();
    let name = format!("test-{}", Uuid::new_v4());
    let volume = database.create_volume(&name).unwrap();

    database.mkdir(volume, "/project/src", true).unwrap();
    database
        .write(
            volume,
            "/project/src/main.rs",
            b"fn main() { /* timeout */ }\n",
        )
        .unwrap();
    database
        .write(volume, "/project/src/lib.rs", b"pub fn library() {}\n")
        .unwrap();

    let entries = database.list(volume, "/project/src").unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(
        database.read(volume, "/project/src/main.rs").unwrap(),
        b"fn main() { /* timeout */ }\n"
    );
    assert_eq!(
        database
            .cat(
                volume,
                &[
                    "/project/src/main.rs".to_owned(),
                    "/project/src/lib.rs".to_owned(),
                ],
            )
            .unwrap(),
        b"fn main() { /* timeout */ }\npub fn library() {}\n"
    );
    assert_eq!(
        database
            .find_paths(volume, "/project/src", Some("*.rs"), Some(1))
            .unwrap(),
        vec!["/project/src/lib.rs", "/project/src/main.rs"]
    );
    assert_eq!(
        database
            .search_literal(volume, "/project", "timeout")
            .unwrap(),
        vec!["/project/src/main.rs"]
    );
    let mut candidates = Vec::new();
    database
        .candidate_text(
            volume,
            "/project/src/main.rs",
            Some(&["timeout".into()]),
            |data| {
                candidates.extend_from_slice(data);
                Ok(())
            },
        )
        .unwrap();
    assert_eq!(candidates, b"fn main() { /* timeout */ }\n");
    // Root traversal must use `/`, not a generated `//` prefix.
    assert!(
        database
            .walk(volume, "/")
            .unwrap()
            .iter()
            .any(|entry| entry.path == "/project/src/main.rs")
    );
    assert_eq!(
        database.search_literal(volume, "/", "timeout").unwrap(),
        vec!["/project/src/main.rs"]
    );

    assert_eq!(
        database
            .copy(volume, "/project/src", "/project/copy", true)
            .unwrap(),
        3
    );
    assert_eq!(
        database
            .move_path(volume, "/project/copy/main.rs", "/project/copy/lib.rs")
            .unwrap(),
        1
    );
    assert_eq!(
        database.read(volume, "/project/copy/lib.rs").unwrap(),
        b"fn main() { /* timeout */ }\n"
    );
    assert_eq!(database.remove(volume, "/project/copy", true).unwrap(), 2);
    assert!(database.stat(volume, "/project/copy").is_err());

    database.remove_volume(volume).unwrap();
}

#[test]
fn multiple_literals_use_one_candidate_query() {
    let Some(database) = test_database() else {
        return;
    };
    database.migrate().unwrap();
    let volume = database
        .create_volume(&format!("literal-or-{}", Uuid::new_v4()))
        .unwrap();
    database.mkdir(volume, "/src", false).unwrap();
    database
        .write(volume, "/src/alpha", b"first needle\n")
        .unwrap();
    database
        .write(volume, "/src/beta", b"second needle\n")
        .unwrap();

    let mut paths = Vec::new();
    database
        .candidate_blocks(
            volume,
            "/src",
            Some(&["first".into(), "second".into()]),
            &[],
            |path, _, _| {
                paths.push(path.to_owned());
                Ok(())
            },
        )
        .unwrap();
    paths.sort();
    assert_eq!(paths, vec!["/src/alpha", "/src/beta"]);
    database.remove_volume(volume).unwrap();
}

#[test]
fn transactions_roll_back_direct_sql_mutations() {
    let Ok(url) = std::env::var("PGOS_TEST_DATABASE_URL") else {
        return;
    };
    let database = Database::connect(&url).unwrap();
    database.migrate().unwrap();
    let name = format!("rollback-{}", Uuid::new_v4());
    let volume = database.create_volume(&name).unwrap();

    let status = std::process::Command::new("psql")
        .arg(&url)
        .arg("-v")
        .arg("ON_ERROR_STOP=1")
        .arg("-c")
        .arg(format!(
            "BEGIN; SELECT pgos.mkdir('{volume}', '/rolled-back', false); ROLLBACK;"
        ))
        .status()
        .unwrap();
    assert!(status.success());
    assert!(database.stat(volume, "/rolled-back").is_err());
    database.remove_volume(volume).unwrap();
}

#[test]
fn copy_import_is_atomic_and_updates_literal_search() {
    let Some(database) = test_database() else {
        eprintln!("skipping: PGOS_TEST_DATABASE_URL is not set");
        return;
    };
    database.migrate().unwrap();
    let name = format!("import-{}", Uuid::new_v4());
    let volume = database.create_volume(&name).unwrap();

    let entries = vec![
        Ok(import_entry("", 2, &[])),
        Ok(import_entry("src", 2, &[])),
        Ok(import_entry(
            "src/main.rs",
            1,
            b"fn main() { /* imported needle */ }\n",
        )),
    ];
    assert_eq!(database.import(volume, "/project", entries).unwrap(), 3);
    assert_eq!(
        sql_scalar(&format!(
            "SELECT count(*) FROM pg_indexes index
             JOIN pgos_private.content_segments segment
               ON index.tablename = pgos_private.segment_relation(segment.id)
             WHERE segment.volume_id = '{volume}'
               AND segment.published
               AND index.indexdef LIKE '%USING btree (object_id, byte_offset)%'"
        )),
        "1"
    );
    assert_eq!(
        database.read(volume, "/project/src/main.rs").unwrap(),
        b"fn main() { /* imported needle */ }\n"
    );
    let imported = database.stat(volume, "/project/src/main.rs").unwrap();
    assert_eq!(imported.mode, 0o644);
    assert_eq!(imported.uid, 1000);
    assert_eq!(imported.gid, 1000);
    assert_eq!(
        imported.size,
        i64::try_from(b"fn main() { /* imported needle */ }\n".len()).unwrap()
    );
    assert_eq!(
        database
            .search_literal(volume, "/project", "imported needle")
            .unwrap(),
        vec!["/project/src/main.rs"]
    );

    let failed = vec![
        Ok(import_entry("", 2, &[])),
        Err(anyhow!("simulated local read failure")),
    ];
    assert!(database.import(volume, "/incomplete", failed).is_err());
    assert!(database.stat(volume, "/incomplete").is_err());

    assert_eq!(database.remove(volume, "/project", true).unwrap(), 3);
    assert_eq!(
        sql_scalar(&format!(
            "SELECT count(*) FROM pgos_private.content_segments
             WHERE volume_id = '{volume}'"
        )),
        "0"
    );

    database.remove_volume(volume).unwrap();
}

#[test]
fn zone_move_preserves_content_search_and_binary_bytes() {
    let Some(database) = test_database() else {
        eprintln!("skipping: PGOS_TEST_DATABASE_URL is not set");
        return;
    };
    database.migrate().unwrap();
    let name = format!("zone-move-{}", Uuid::new_v4());
    let volume = database.create_volume(&name).unwrap();
    let binary = [0, 159, 146, 150, 255];
    let entries = vec![
        Ok(import_entry("", 2, &[])),
        Ok(import_entry("src", 2, &[])),
        Ok(import_entry("src/main.rs", 1, b"indexed needle\n")),
        Ok(import_entry("src/data.bin", 1, &binary)),
    ];

    assert_eq!(database.import(volume, "/before", entries).unwrap(), 4);
    assert_eq!(database.move_path(volume, "/before", "/after").unwrap(), 4);
    assert_eq!(
        database.disk_usage(volume, "/after").unwrap(),
        i64::try_from(b"indexed needle\n".len() + binary.len()).unwrap()
    );
    assert!(database.stat(volume, "/before").is_err());
    assert_eq!(
        database
            .find_paths(volume, "/after", Some("*.rs"), Some(1))
            .unwrap(),
        vec!["/after/src/main.rs"]
    );
    assert_eq!(
        database
            .search_literal(volume, "/after", "indexed needle")
            .unwrap(),
        vec!["/after/src/main.rs"]
    );
    assert_eq!(
        database.read(volume, "/after/src/data.bin").unwrap(),
        binary
    );
    database
        .write(volume, "/after/src/main.rs", b"short\n")
        .unwrap();
    assert_eq!(
        database.disk_usage(volume, "/after").unwrap(),
        i64::try_from(b"short\n".len() + binary.len()).unwrap()
    );

    let directories = (0..1_000)
        .map(|index| format!("/after/d{index:04}"))
        .collect::<Vec<_>>();
    database.mkdir_many(volume, &directories, false).unwrap();
    assert_eq!(
        database
            .remove_many(volume, &directories, false, false)
            .unwrap(),
        1_000
    );
    assert_eq!(database.remove(volume, "/after", true).unwrap(), 4);
    database.remove_volume(volume).unwrap();
}

fn import_entry(relative_path: &str, kind: i16, content: &[u8]) -> ImportEntry {
    ImportEntry {
        relative_path: relative_path.to_owned(),
        kind,
        content: content.to_vec(),
        mode: if kind == 2 { 0o755 } else { 0o644 },
        uid: 1000,
        gid: 1000,
        mtime_seconds: 1_700_000_000,
        mtime_nanoseconds: 123_000_000,
        link_target: String::new(),
    }
}
