use galaxybridge_quic_media::{control::Writer, wire::Record, MS};

fn record(kind: u8, sequence: u64, body: Vec<u8>) -> Record {
    Record {
        kind,
        track: 0,
        flags: 0,
        generation: 1,
        epoch: 1,
        config: 0,
        sequence,
        pts: 0,
        total: body.len() as u32,
        index: 0,
        count: 1,
        age_us: 0,
        lifetime_us: if kind == 9 { 40_000 } else { 500_000 },
        body,
    }
}

fn touch(action: u8, x: u32) -> Vec<u8> {
    let mut raw = vec![0; 32];
    raw[0] = 2;
    raw[1] = action;
    raw[9] = 1;
    raw[10..14].copy_from_slice(&x.to_be_bytes());
    raw[18..20].copy_from_slice(&100u16.to_be_bytes());
    raw[20..22].copy_from_slice(&100u16.to_be_bytes());
    raw
}

fn critical(action: u8, sequence: u64, final_move: u64) -> Record {
    let mut body = vec![0; 36];
    body[0] = match action {
        0 => 1,
        1 => 2,
        3 => 3,
        _ => unreachable!(),
    };
    body[15] = 1;
    body[23] = 1;
    body[24..32].copy_from_slice(&final_move.to_be_bytes());
    body[32..36].copy_from_slice(&32u32.to_be_bytes());
    body.extend(touch(action, if action == 0 { 10 } else { 80 }));
    record(8, sequence, body)
}

fn movement(sequence: u64, x: u32) -> Record {
    let mut body = vec![0; 28];
    body[7] = 1;
    body[15] = 1;
    body[23] = 1; // Ordered behind DOWN sequence 1.
    body[27] = 32;
    body.extend(touch(2, x));
    record(9, sequence, body)
}

fn write(writer: &mut Writer, now: u64) -> Vec<u8> {
    let lease = writer
        .next_write(now)
        .expect("expected stock control bytes");
    let bytes = lease.bytes.as_slice()[lease.offset..].to_vec();
    writer.write_result(lease.token, bytes.len(), now).unwrap();
    bytes
}

#[test]
fn latest_queued_move_is_written_before_its_up() {
    let mut writer = Writer::new(1);
    writer.ingest(critical(0, 1, 0), 0).unwrap();
    assert_eq!(write(&mut writer, 0), touch(0, 10));
    writer.ingest(movement(1, 40), MS).unwrap();
    writer.ingest(movement(2, 80), 2 * MS).unwrap();
    writer.ingest(critical(1, 2, 2), 3 * MS).unwrap();
    assert_eq!(write(&mut writer, 3 * MS), touch(2, 80));
    assert_eq!(write(&mut writer, 3 * MS), touch(1, 80));
    assert!(writer.next_write(3 * MS).is_none());
    assert!(writer.pointers().is_empty());
}

#[test]
fn move_received_during_partial_down_survives_until_up() {
    let mut writer = Writer::new(1);
    writer.ingest(critical(0, 1, 0), 0).unwrap();
    let down = writer.next_write(0).unwrap();
    writer.write_result(down.token, 1, 0).unwrap();
    writer.ingest(movement(1, 80), MS).unwrap();
    writer.ingest(critical(1, 2, 1), 2 * MS).unwrap();
    assert_eq!(write(&mut writer, 2 * MS), touch(0, 10)[1..]);
    assert_eq!(write(&mut writer, 2 * MS), touch(2, 80));
    assert_eq!(write(&mut writer, 2 * MS), touch(1, 80));
}

#[test]
fn move_received_while_down_is_queued_survives_until_up() {
    let mut writer = Writer::new(1);
    writer.ingest(critical(0, 1, 0), 0).unwrap();
    writer.ingest(movement(1, 80), MS).unwrap();
    writer.ingest(critical(1, 2, 1), 2 * MS).unwrap();
    assert_eq!(write(&mut writer, 2 * MS), touch(0, 10));
    assert_eq!(write(&mut writer, 2 * MS), touch(2, 80));
    assert_eq!(write(&mut writer, 2 * MS), touch(1, 80));
}

#[test]
fn cancel_discards_unwritten_moves_even_before_down_completion() {
    for pending_down in [false, true] {
        let mut writer = Writer::new(1);
        writer.ingest(critical(0, 1, 0), 0).unwrap();
        if !pending_down {
            write(&mut writer, 0);
        }
        writer.ingest(movement(1, 80), MS).unwrap();
        writer.ingest(critical(3, 2, 1), 2 * MS).unwrap();
        if pending_down {
            assert_eq!(write(&mut writer, 2 * MS), touch(0, 10));
        }
        assert_eq!(write(&mut writer, 2 * MS), touch(3, 80));
        assert!(writer.next_write(2 * MS).is_none());
    }
}

#[test]
fn expired_move_never_delays_up_or_extends_its_freshness() {
    let mut writer = Writer::new(1);
    writer.ingest(critical(0, 1, 0), 0).unwrap();
    write(&mut writer, 0);
    writer.ingest(movement(1, 80), MS).unwrap();
    writer.ingest(critical(1, 2, 1), 2 * MS).unwrap();
    assert_eq!(write(&mut writer, 41 * MS), touch(1, 80));
    assert!(writer.next_write(41 * MS).is_none());
    assert_eq!(writer.terminal(), None);
}
