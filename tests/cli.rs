use assert_cmd::Command;
use predicates::prelude::*;
use std::fs;
use tempfile::TempDir;
use uuid::Uuid;

#[test]
fn cli_runs_sql_aware_file_flow() {
    let Ok(url) = std::env::var("PGOS_TEST_DATABASE_URL") else {
        return;
    };
    let volume = format!("cli-{}", Uuid::new_v4());
    let source = TempDir::new().unwrap();
    fs::write(source.path().join("readme.txt"), "hello postgres").unwrap();
    fs::write(source.path().join("end.txt"), "goodbye").unwrap();

    pgos(&url, &volume).arg("init").assert().success();
    pgos(&url, &volume)
        .args(["volume", "create", &volume])
        .assert()
        .success();
    pgos(&url, &volume)
        .arg("import")
        .arg(source.path())
        .arg("/docs")
        .assert()
        .success();
    pgos(&url, &volume)
        .args(["find", "/docs", "--name", "*.txt", "--type", "f"])
        .assert()
        .success()
        .stdout("/docs/end.txt\n/docs/readme.txt\n");
    pgos(&url, &volume)
        .args(["cp", "-r", "/docs", "/docs-copy"])
        .assert()
        .success();
    pgos(&url, &volume)
        .args(["find", "/docs-copy", "--type", "f"])
        .assert()
        .success()
        .stdout("/docs-copy/end.txt\n/docs-copy/readme.txt\n");
    pgos(&url, &volume)
        .args(["grep", "-r", "-F", "postgres", "/docs"])
        .assert()
        .success()
        .stdout(predicate::str::contains("/docs/readme.txt:hello postgres"));
    // Match grep's distinct status for a valid search with no matches.
    pgos(&url, &volume)
        .args(["grep", "-r", "-F", "absent", "/docs"])
        .assert()
        .code(1)
        .stdout("");
    pgos(&url, &volume)
        .args(["rm", "-r", "/docs", "/docs-copy"])
        .assert()
        .success();
}

#[test]
fn installed_tool_names_use_sql_and_fallback() {
    let Ok(url) = std::env::var("PGOS_TEST_DATABASE_URL") else {
        return;
    };
    let volume = format!("tools-{}", Uuid::new_v4());
    let tools = TempDir::new().unwrap();
    let source = TempDir::new().unwrap();
    fs::write(source.path().join("one.txt"), "indexed text").unwrap();

    pgos(&url, &volume).arg("init").assert().success();
    pgos(&url, &volume)
        .args(["volume", "create", &volume])
        .assert()
        .success();
    pgos(&url, &volume)
        .arg("import")
        .arg(source.path())
        .arg("/docs")
        .assert()
        .success();
    pgos(&url, &volume)
        .arg("tools")
        .arg("install")
        .arg(tools.path())
        .assert()
        .success();
    for name in ["ls", "cat", "touch", "mkdir", "mv"] {
        assert!(
            !tools.path().join(name).exists(),
            "installed obsolete {name} link"
        );
    }
    assert!(tools.path().join("cp").exists());

    let mut sql_find = Command::new(tools.path().join("find"));
    sql_find
        .env("PGOS_DATABASE_URL", &url)
        .env("PGOS_VOLUME", &volume)
        .env("PGOS_MOUNT", "/data")
        .env("PGOS_DIAGNOSTICS", "true")
        .args(["/data/docs", "-type", "f"])
        .assert()
        .success()
        .stdout("/data/docs/one.txt\n")
        .stderr(predicate::str::contains("using direct SQL acceleration"));

    let mut fallback_find = Command::new(tools.path().join("find"));
    fallback_find
        .env("PGOS_DATABASE_URL", &url)
        .env("PGOS_VOLUME", &volume)
        .env("PGOS_MOUNT", "/data")
        .env("PGOS_DIAGNOSTICS", "true")
        .args(["/tmp", "-maxdepth", "0"])
        .assert()
        .success()
        .stderr(predicate::str::contains("falling back"));

    let local_source = tools.path().join("local-source");
    let local_destination = tools.path().join("local-destination");
    fs::write(&local_source, "native copy").unwrap();
    let mut fallback_cp = Command::new(tools.path().join("cp"));
    fallback_cp
        .env("PGOS_DATABASE_URL", &url)
        .env("PGOS_VOLUME", &volume)
        .env("PGOS_MOUNT", "/data")
        .env("PGOS_DIAGNOSTICS", "true")
        .arg(&local_source)
        .arg(&local_destination)
        .assert()
        .success()
        .stderr(predicate::str::contains("falling back"));
    assert_eq!(
        fs::read_to_string(local_destination).unwrap(),
        "native copy"
    );
}

#[test]
fn cli_imports_a_local_tree_with_search_ready_at_commit() {
    let Ok(url) = std::env::var("PGOS_TEST_DATABASE_URL") else {
        return;
    };
    let volume = format!("import-cli-{}", Uuid::new_v4());
    let source = TempDir::new().unwrap();
    fs::create_dir(source.path().join("src")).unwrap();
    fs::write(
        source.path().join("src/main.rs"),
        b"fn main() { /* batch import */ }\n",
    )
    .unwrap();
    fs::write(source.path().join("binary.dat"), [0, 159, 146, 150]).unwrap();

    pgos(&url, &volume).arg("init").assert().success();
    pgos(&url, &volume)
        .args(["volume", "create", &volume])
        .assert()
        .success();
    pgos(&url, &volume)
        .arg("import")
        .arg(source.path())
        .arg("/project")
        .assert()
        .success()
        .stdout("");
    pgos(&url, &volume)
        .args(["grep", "-r", "-F", "batch import", "/project"])
        .assert()
        .success()
        .stdout(predicate::str::contains("/project/src/main.rs"));

    // The destination-exists error leaves the first import unchanged.
    pgos(&url, &volume)
        .arg("import")
        .arg(source.path())
        .arg("/project")
        .assert()
        .failure();
    pgos(&url, &volume)
        .args(["grep", "-r", "-F", "batch import", "/project"])
        .assert()
        .success()
        .stdout(predicate::str::contains("/project/src/main.rs"));
}

#[test]
fn configured_socket_does_not_fall_back_to_postgresql() {
    let directory = TempDir::new().unwrap();
    let missing_socket = directory.path().join("missing.sock");
    let mut command = Command::cargo_bin("pgos").unwrap();
    command
        .env("PGOS_SOCKET", &missing_socket)
        .env("PGOS_DATABASE_URL", "postgresql://invalid.invalid/unused")
        .args(["find", "/"])
        .assert()
        .failure()
        .stderr(
            predicate::str::contains("could not connect to pgosd socket")
                .and(predicate::str::contains("could not connect to PostgreSQL").not()),
        );
}

fn pgos(url: &str, volume: &str) -> Command {
    let mut command = Command::cargo_bin("pgos").unwrap();
    command
        .env("PGOS_DATABASE_URL", url)
        .env("PGOS_VOLUME", volume);
    command
}
