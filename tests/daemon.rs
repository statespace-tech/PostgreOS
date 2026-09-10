use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use postgreos::client::Client;
use postgreos::postgres::Database;
use tempfile::TempDir;
use uuid::Uuid;

struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn daemon_serves_repeated_database_operations() {
    let Ok(url) = std::env::var("PGOS_TEST_DATABASE_URL") else {
        return;
    };
    let database = Database::connect(&url).unwrap();
    database.migrate().unwrap();
    let volume_name = format!("daemon-{}", Uuid::new_v4());
    let volume = database.create_volume(&volume_name).unwrap();
    let directory = TempDir::new().unwrap();
    let socket = directory.path().join("pgosd.sock");
    let child = Command::new(env!("CARGO_BIN_EXE_pgosd"))
        .args(["--database-url", &url, "--socket"])
        .arg(&socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let _guard = ChildGuard(child);

    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    let client = Client::connect(&socket, &volume_name).unwrap();
    client.mkdir("/docs", false).unwrap();
    client.write("/docs/readme.txt", b"hello").unwrap();
    assert_eq!(client.read("/docs/readme.txt").unwrap(), b"hello");
    assert_eq!(client.list("/docs").unwrap()[0].name, "readme.txt");
    let mut output = Vec::new();
    assert!(
        client
            .grep_regex_output("/docs", "hello", false, "", &[], &mut output)
            .unwrap()
    );
    assert_eq!(output, b"/docs/readme.txt:hello\n");

    database.remove_volume(volume).unwrap();
}
