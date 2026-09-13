use galaxybridge_file_receiver::{hexadecimal, Failure, Manifest, Receiver, CHUNK_SIZE};
use serde::Deserialize;
use serde_json::json;
use std::io::{self, BufRead, Read, Write};
use std::path::PathBuf;

#[derive(Deserialize)]
struct Request {
    session_id: String,
    request_id: u64,
    #[serde(flatten)]
    command: Command,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Begin {
        manifest: Manifest,
    },
    Append {
        offset: u64,
        length: usize,
        sha256: String,
    },
    Status,
    Commit,
    Cancel,
}
fn emit(value: serde_json::Value) -> Result<(), Failure> {
    let mut output = io::stdout().lock();
    serde_json::to_writer(&mut output, &value).map_err(|_| Failure("transport_closed"))?;
    output
        .write_all(b"\n")
        .and_then(|_| output.flush())
        .map_err(|_| Failure("transport_closed"))
}
fn run() -> Result<(), Failure> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 3 && args[1] == "--probe" {
        let result =
            galaxybridge_file_receiver::probe_atomic_publication(std::path::Path::new(&args[2]));
        emit(json!({"atomic_no_replace": result.is_ok()}))?;
        return result;
    }
    if args.len() == 2 && args[1] == "--version" {
        println!("galaxybridge-file-receiver 1");
        return Ok(());
    }
    if args.len() != 7
        || args[1] != "--destination"
        || args[3] != "--state"
        || args[5] != "--owner"
        || !hexadecimal(&args[6], 64)
    {
        return Err(Failure("invalid_arguments"));
    }
    let destination = PathBuf::from(&args[2]);
    let state = PathBuf::from(&args[4]);
    let owner = &args[6];
    let mut receiver: Option<Receiver> = None;
    let mut session = String::new();
    let mut sequence = 0;
    let stdin = io::stdin();
    let mut input = stdin.lock();
    loop {
        let mut header = Vec::new();
        let count = input.by_ref().take(4097).read_until(b'\n', &mut header)?;
        if count == 0 {
            return Ok(());
        } // EOF is pause, never implicit commit/cancel.
        if count > 4096 || !header.ends_with(b"\n") {
            return Err(Failure("invalid_header"));
        }
        let request: Request =
            serde_json::from_slice(&header).map_err(|_| Failure("invalid_header"))?;
        if !hexadecimal(&request.session_id, 32)
            || request.request_id != sequence + 1
            || (!session.is_empty() && session != request.session_id)
        {
            return Err(Failure("stale_request"));
        }
        session = request.session_id;
        sequence = request.request_id;
        let mut progress = |bytes| {
            emit(
                json!({"kind":"progress", "session_id":session, "request_id":sequence, "bytes":bytes}),
            )
        };
        let result = (|| match request.command {
            Command::Begin { manifest } => {
                if receiver.is_some() || manifest.owner != *owner {
                    return Err(Failure("owner_mismatch"));
                }
                receiver = Some(Receiver::begin(
                    &destination,
                    &state,
                    manifest,
                    &mut progress,
                )?);
                Ok(receiver.as_ref().unwrap().status())
            }
            Command::Append {
                offset,
                length,
                sha256,
            } => {
                if length == 0 || length > CHUNK_SIZE {
                    return Err(Failure("invalid_chunk"));
                }
                let mut bytes = vec![0u8; length];
                input.read_exact(&mut bytes)?;
                receiver
                    .as_mut()
                    .ok_or(Failure("begin_required"))?
                    .append(offset, &bytes, &sha256)
            }
            Command::Status => Ok(receiver.as_ref().ok_or(Failure("begin_required"))?.status()),
            Command::Commit => receiver
                .as_mut()
                .ok_or(Failure("begin_required"))?
                .commit(&mut progress),
            Command::Cancel => receiver
                .as_mut()
                .ok_or(Failure("begin_required"))?
                .cancel(&mut progress),
        })();
        match result {
            Ok(status) => emit(
                json!({"kind":"ack", "session_id":session, "request_id":sequence, "status":status}),
            )?,
            Err(error) => {
                let _ = emit(
                    json!({"kind":"error", "session_id":session, "request_id":sequence, "code":error.0}),
                );
                return Err(error); // Reopen/reconcile after any uncertain disk outcome.
            }
        }
    }
}
fn main() {
    // Never print raw OS errors, content, paths or device identities.
    if run().is_err() {
        std::process::exit(1);
    }
}
