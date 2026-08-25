use std::env;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE;
use chrono::{DateTime, SecondsFormat, Utc};
use data_encoding::BASE32_NOPAD;
use nym_sphinx_types::crypto::{PrivateKey, PublicKey};
use nym_sphinx_types::header::{HEADER_SIZE, delays::Delay};
use nym_sphinx_types::{
    Destination, DestinationAddressBytes, Node, NodeAddressBytes, PAYLOAD_OVERHEAD_SIZE,
    ProcessedPacketData, SphinxPacket, SphinxPacketBuilder, SURB, SURBMaterial,
};
use reed_solomon_erasure::galois_8::ReedSolomon;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use zeroize::Zeroizing;

const PROTOCOL: &str = "ouo-onion-sidecar/1";
const NODE_ID_PREFIX: &str = "ouo-node-v1-";
const MAX_FRAME: usize = 12 * 1024 * 1024;
const MAX_PAYLOAD: usize = 96 * 1024;
const MAX_CONTAINER: usize = 4 * 1024 * 1024;
const MAX_SHARD: usize = 1024 * 1024;
const MAX_ERASURE_WIRE: usize = 8 * 1024 * 1024;
const PACKET_CLASSES: [usize; 4] = [4 * 1024, 16 * 1024, 64 * 1024, 256 * 1024];
const FINAL_MAGIC: &[u8; 8] = b"OUOSPX01";
const SURB_MAGIC: &[u8; 8] = b"OUOSURB1";
const ERASURE_MAGIC: &[u8; 8] = b"OUORS001";
const CAPABILITY_BIT: u64 = 1 << 63;
const VALUE_MASK: u64 = CAPABILITY_BIT - 1;

#[derive(Deserialize)]
struct CommonRequest {
    protocol_version: String,
    request_id: String,
    operation: String,
    #[serde(flatten)]
    body: serde_json::Map<String, Value>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuildRequest {
    route: Vec<RouteHop>,
    payload_b64: String,
    expires_at: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RouteHop {
    node_id: String,
    capability: Capability,
    public_key_b64: String,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Capability {
    Relay,
    Home,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnwrapRequest {
    private_key_b64: String,
    packet_b64: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuildReplyRequest {
    surb_b64: String,
    payload_b64: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CreateReplyBlockRequest {
    route: Vec<RouteHop>,
    expires_at: String,
    packet_size: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ErasureEncodeRequest {
    required: usize,
    total: usize,
    payload_b64: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ErasureReconstructRequest {
    required: usize,
    total: usize,
    shards: Vec<EncodedShard>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EncodedShard {
    index: usize,
    data_b64: String,
}

#[derive(Serialize)]
struct Response {
    protocol_version: &'static str,
    request_id: String,
    ok: bool,
    #[serde(flatten)]
    body: Value,
}

#[tokio::main]
async fn main() -> io::Result<()> {
    let socket_path = env::var("OUO_SPHINX_SOCKET")
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "OUO_SPHINX_SOCKET is required"))?;
    let path = Path::new(&socket_path);
    if path.exists() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "refusing to replace an existing sidecar socket path",
        ));
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;

    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                tokio::spawn(async move {
                    let _ = serve_connection(stream).await;
                });
            }
            _ = tokio::signal::ctrl_c() => break,
        }
    }
    Ok(())
}

async fn serve_connection(mut stream: UnixStream) -> io::Result<()> {
    loop {
        let size = match stream.read_u32().await {
            Ok(value) => value as usize,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error),
        };
        if size == 0 || size > MAX_FRAME {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid frame size"));
        }
        let mut encoded = vec![0_u8; size];
        stream.read_exact(&mut encoded).await?;
        let response = dispatch(&encoded);
        let encoded = serde_json::to_vec(&response)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "response encoding failed"))?;
        if encoded.len() > MAX_FRAME {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "response exceeds frame limit"));
        }
        stream.write_u32(encoded.len() as u32).await?;
        stream.write_all(&encoded).await?;
        stream.flush().await?;
    }
}

fn dispatch(encoded: &[u8]) -> Response {
    let request: CommonRequest = match serde_json::from_slice(encoded) {
        Ok(value) => value,
        Err(_) => return failure("", "invalid_request"),
    };
    if request.protocol_version != PROTOCOL || !valid_request_id(&request.request_id) {
        return failure(&request.request_id, "invalid_protocol_binding");
    }
    let result = match request.operation.as_str() {
        "build" => serde_json::from_value::<BuildRequest>(Value::Object(request.body))
            .map_err(|_| "invalid_build")
            .and_then(build_packet),
        "unwrap" => serde_json::from_value::<UnwrapRequest>(Value::Object(request.body))
            .map_err(|_| "invalid_unwrap")
            .and_then(unwrap_packet),
        "build_reply" => serde_json::from_value::<BuildReplyRequest>(Value::Object(request.body))
            .map_err(|_| "invalid_build_reply")
            .and_then(build_reply_packet),
        "create_reply_block" => serde_json::from_value::<CreateReplyBlockRequest>(Value::Object(request.body))
            .map_err(|_| "invalid_create_reply_block")
            .and_then(create_reply_block),
        "erasure_encode" => serde_json::from_value::<ErasureEncodeRequest>(Value::Object(request.body))
            .map_err(|_| "invalid_erasure_encode")
            .and_then(erasure_encode),
        "erasure_reconstruct" => serde_json::from_value::<ErasureReconstructRequest>(Value::Object(request.body))
            .map_err(|_| "invalid_erasure_reconstruct")
            .and_then(erasure_reconstruct),
        _ => Err("unsupported_operation"),
    };
    match result {
        Ok(body) => Response {
            protocol_version: PROTOCOL,
            request_id: request.request_id.clone(),
            ok: true,
            body,
        },
        Err(code) => failure(&request.request_id, code),
    }
}

fn create_reply_block(request: CreateReplyBlockRequest) -> Result<Value, &'static str> {
    if !(2..=5).contains(&request.route.len())
        || !PACKET_CLASSES.contains(&request.packet_size)
        || request
            .route
            .last()
            .map(|hop| !matches!(hop.capability, Capability::Home))
            .unwrap_or(true)
        || request.route[..request.route.len() - 1]
            .iter()
            .any(|hop| !matches!(hop.capability, Capability::Relay))
    {
        return Err("invalid_route");
    }
    let expiry = parse_expiry(&request.expires_at)?;
    let now = Utc::now();
    if expiry <= now || expiry.signed_duration_since(now).num_seconds() > 330 {
        return Err("invalid_expiry");
    }
    let expiry_ms = u64::try_from(expiry.timestamp_millis()).map_err(|_| "invalid_expiry")?;
    if expiry_ms > VALUE_MASK {
        return Err("invalid_expiry");
    }
    let mut route = Vec::with_capacity(request.route.len());
    for hop in &request.route {
        route.push(Node::new(
            NodeAddressBytes::from_bytes(decode_node_id(&hop.node_id)?),
            PublicKey::from(decode_exact_32(&hop.public_key_b64)?),
        ));
    }
    let destination_id = decode_node_id(&request.route.last().ok_or("invalid_route")?.node_id)?;
    let destination = Destination::new(
        DestinationAddressBytes::from_bytes(destination_id),
        [0_u8; 16],
    );
    let mut delays = Vec::with_capacity(route.len());
    for next in request.route.iter().skip(1) {
        let capability = if matches!(next.capability, Capability::Home) {
            CAPABILITY_BIT
        } else {
            0
        };
        delays.push(Delay::new_from_nanos(capability | expiry_ms));
    }
    delays.push(Delay::new_from_nanos(0));
    let surb = SURBMaterial::new(route, delays, destination)
        .construct_SURB()
        .map_err(|_| "surb_creation_failed")?;
    let raw = surb.to_bytes();
    let mut wrapped = Vec::with_capacity(20 + raw.len());
    wrapped.extend_from_slice(SURB_MAGIC);
    wrapped.extend_from_slice(&expiry_ms.to_be_bytes());
    wrapped.extend_from_slice(&(request.packet_size as u32).to_be_bytes());
    wrapped.extend_from_slice(&raw);
    if wrapped.len() > 256 * 1024 {
        return Err("surb_too_large");
    }
    Ok(json!({
        "surb_b64": URL_SAFE.encode(wrapped),
        "expires_at": expiry_from_millis(expiry_ms)?,
    }))
}

fn erasure_encode(request: ErasureEncodeRequest) -> Result<Value, &'static str> {
    validate_erasure_parameters(request.required, request.total)?;
    let payload = decode_b64(&request.payload_b64, MAX_CONTAINER)?;
    if payload.is_empty() {
        return Err("invalid_container");
    }
    let payload_len = u32::try_from(payload.len()).map_err(|_| "container_too_large")?;
    let mut framed = Vec::with_capacity(14 + payload.len());
    framed.extend_from_slice(ERASURE_MAGIC);
    framed.push(request.required as u8);
    framed.push(request.total as u8);
    framed.extend_from_slice(&payload_len.to_be_bytes());
    framed.extend_from_slice(&payload);

    let shard_size = framed.len().div_ceil(request.required);
    if shard_size == 0 || shard_size > MAX_SHARD {
        return Err("shard_too_large");
    }
    if shard_size.checked_mul(request.total).is_none_or(|size| size > MAX_ERASURE_WIRE) {
        return Err("erasure_wire_budget_exceeded");
    }
    framed.resize(shard_size * request.required, 0);
    let mut shards = Vec::with_capacity(request.total);
    for index in 0..request.required {
        shards.push(framed[index * shard_size..(index + 1) * shard_size].to_vec());
    }
    shards.resize_with(request.total, || vec![0_u8; shard_size]);
    ReedSolomon::new(request.required, request.total - request.required)
        .map_err(|_| "invalid_erasure_parameters")?
        .encode(&mut shards)
        .map_err(|_| "erasure_encode_failed")?;

    Ok(json!({
        "shards": shards.into_iter().enumerate().map(|(index, data)| {
            json!({"index": index, "data_b64": URL_SAFE.encode(data)})
        }).collect::<Vec<_>>()
    }))
}

fn erasure_reconstruct(request: ErasureReconstructRequest) -> Result<Value, &'static str> {
    validate_erasure_parameters(request.required, request.total)?;
    if request.shards.len() < request.required || request.shards.len() > request.total {
        return Err("invalid_shard_count");
    }
    let mut values: Vec<Option<Vec<u8>>> = vec![None; request.total];
    let mut shard_size = None;
    for shard in request.shards {
        if shard.index >= request.total || values[shard.index].is_some() {
            return Err("invalid_shard_index");
        }
        let data = decode_b64(&shard.data_b64, MAX_SHARD)?;
        if data.is_empty() || shard_size.is_some_and(|size| size != data.len()) {
            return Err("invalid_shard_geometry");
        }
        shard_size = Some(data.len());
        values[shard.index] = Some(data);
    }
    if shard_size
        .and_then(|size| size.checked_mul(request.total))
        .is_none_or(|size| size > MAX_ERASURE_WIRE)
    {
        return Err("erasure_wire_budget_exceeded");
    }
    ReedSolomon::new(request.required, request.total - request.required)
        .map_err(|_| "invalid_erasure_parameters")?
        .reconstruct(&mut values)
        .map_err(|_| "erasure_reconstruct_failed")?;

    let mut framed = Vec::with_capacity(
        request.required * shard_size.ok_or("invalid_shard_geometry")?,
    );
    for value in values.iter().take(request.required) {
        framed.extend_from_slice(value.as_ref().ok_or("erasure_reconstruct_failed")?);
    }
    if framed.len() < 14 || &framed[..8] != ERASURE_MAGIC {
        return Err("invalid_reconstructed_container");
    }
    if framed[8] as usize != request.required || framed[9] as usize != request.total {
        return Err("erasure_parameter_mismatch");
    }
    let payload_len = u32::from_be_bytes(
        framed[10..14]
            .try_into()
            .map_err(|_| "invalid_reconstructed_container")?,
    ) as usize;
    if payload_len == 0 || payload_len > MAX_CONTAINER || 14 + payload_len > framed.len() {
        return Err("invalid_reconstructed_container");
    }
    Ok(json!({"payload_b64": URL_SAFE.encode(&framed[14..14 + payload_len])}))
}

fn validate_erasure_parameters(required: usize, total: usize) -> Result<(), &'static str> {
    if !(2..=64).contains(&required) || required > total || total > 64 {
        return Err("invalid_erasure_parameters");
    }
    Ok(())
}

fn failure(request_id: &str, code: &str) -> Response {
    Response {
        protocol_version: PROTOCOL,
        request_id: request_id.to_owned(),
        ok: false,
        body: json!({"error_code": code}),
    }
}

fn build_packet(request: BuildRequest) -> Result<Value, &'static str> {
    if !(2..=5).contains(&request.route.len()) || request.route.last().map(|h| !matches!(h.capability, Capability::Home)).unwrap_or(true) {
        return Err("invalid_route");
    }
    if request.route[..request.route.len() - 1]
        .iter()
        .any(|hop| !matches!(hop.capability, Capability::Relay))
    {
        return Err("invalid_route");
    }
    let expiry = parse_expiry(&request.expires_at)?;
    let now = Utc::now();
    if expiry <= now || expiry.signed_duration_since(now).num_seconds() > 330 {
        return Err("invalid_expiry");
    }
    let expiry_ms = u64::try_from(expiry.timestamp_millis()).map_err(|_| "invalid_expiry")?;
    if expiry_ms > VALUE_MASK {
        return Err("invalid_expiry");
    }
    let payload = decode_b64(&request.payload_b64, MAX_PAYLOAD)?;
    if payload.is_empty() {
        return Err("invalid_payload");
    }
    let final_payload = encode_final_payload(expiry_ms, &payload)?;
    let packet_class = PACKET_CLASSES
        .into_iter()
        .find(|size| size - HEADER_SIZE >= final_payload.len() + PAYLOAD_OVERHEAD_SIZE)
        .ok_or("payload_too_large")?;

    let mut route = Vec::with_capacity(request.route.len());
    for hop in &request.route {
        let address = decode_node_id(&hop.node_id)?;
        let public_key = decode_exact_32(&hop.public_key_b64)?;
        route.push(Node::new(
            NodeAddressBytes::from_bytes(address),
            PublicKey::from(public_key),
        ));
    }
    let destination_id = decode_node_id(&request.route.last().ok_or("invalid_route")?.node_id)?;
    let destination = Destination::new(
        DestinationAddressBytes::from_bytes(destination_id),
        [0_u8; 16],
    );
    let mut delays = Vec::with_capacity(route.len());
    for next in request.route.iter().skip(1) {
        let capability = if matches!(next.capability, Capability::Home) {
            CAPABILITY_BIT
        } else {
            0
        };
        delays.push(Delay::new_from_nanos(capability | expiry_ms));
    }
    delays.push(Delay::new_from_nanos(0));

    let packet = SphinxPacketBuilder::new()
        .with_payload_size(packet_class - HEADER_SIZE)
        .build_packet(final_payload, &route, &destination, &delays)
        .map_err(|_| "sphinx_build_failed")?;
    let bytes = packet.to_bytes();
    if bytes.len() != packet_class {
        return Err("invalid_packet_geometry");
    }
    Ok(json!({"packet_b64": URL_SAFE.encode(bytes)}))
}

fn build_reply_packet(request: BuildReplyRequest) -> Result<Value, &'static str> {
    let wrapped_surb = Zeroizing::new(decode_b64(&request.surb_b64, 256 * 1024)?);
    let payload = decode_b64(&request.payload_b64, MAX_PAYLOAD)?;
    if payload.is_empty() || wrapped_surb.len() < 20 || &wrapped_surb[..8] != SURB_MAGIC {
        return Err("invalid_surb");
    }
    let expiry_ms = u64::from_be_bytes(
        wrapped_surb[8..16].try_into().map_err(|_| "invalid_surb")?,
    );
    let packet_class = u32::from_be_bytes(
        wrapped_surb[16..20].try_into().map_err(|_| "invalid_surb")?,
    ) as usize;
    if !PACKET_CLASSES.contains(&packet_class) {
        return Err("invalid_surb");
    }
    let expiry = expiry_from_millis(expiry_ms)?;
    let parsed_expiry = parse_expiry(&expiry)?;
    let now = Utc::now();
    if parsed_expiry <= now || parsed_expiry.signed_duration_since(now).num_seconds() > 330 {
        return Err("invalid_surb");
    }
    let surb = SURB::from_bytes(&wrapped_surb[20..]).map_err(|_| "invalid_surb")?;
    let final_payload = encode_final_payload(expiry_ms, &payload)?;
    if packet_class - HEADER_SIZE < final_payload.len() + PAYLOAD_OVERHEAD_SIZE {
        return Err("payload_too_large");
    }
    let (packet, first_hop) = surb
        .use_surb(&final_payload, packet_class - HEADER_SIZE)
        .map_err(|_| "surb_build_failed")?;
    let packet = packet.to_bytes();
    if packet.len() != packet_class {
        return Err("invalid_packet_geometry");
    }
    Ok(json!({
        "first_node_id": encode_node_id(first_hop.to_bytes()),
        "packet_b64": URL_SAFE.encode(packet),
        "expires_at": expiry,
    }))
}

fn unwrap_packet(request: UnwrapRequest) -> Result<Value, &'static str> {
    let private_key = Zeroizing::new(decode_exact_32(&request.private_key_b64)?);
    let packet_bytes = decode_b64(&request.packet_b64, 256 * 1024)?;
    if !PACKET_CLASSES.contains(&packet_bytes.len()) {
        return Err("invalid_packet_geometry");
    }
    let packet = SphinxPacket::from_bytes(&packet_bytes).map_err(|_| "invalid_sphinx_packet")?;
    let secret = PrivateKey::from(*private_key);
    let expanded = packet.header.compute_expanded_shared_secret(&secret);
    let replay_tag = expanded.replay_tag().to_vec();
    let processed = packet
        .process_with_expanded_secret(&expanded)
        .map_err(|_| "sphinx_unwrap_failed")?;

    match processed.data {
        ProcessedPacketData::ForwardHop {
            next_hop_packet,
            next_hop_address,
            delay,
        } => {
            let metadata = delay.to_nanos();
            let capability = if metadata & CAPABILITY_BIT == 0 { "relay" } else { "home" };
            let expiry = expiry_from_millis(metadata & VALUE_MASK)?;
            let next = next_hop_packet.to_bytes();
            if next.len() != packet_bytes.len() {
                return Err("invalid_packet_geometry");
            }
            Ok(json!({
                "next_node_id": encode_node_id(next_hop_address.to_bytes()),
                "next_capability": capability,
                "next_packet_b64": URL_SAFE.encode(next),
                "final_payload_b64": null,
                "replay_tag_b64": URL_SAFE.encode(replay_tag),
                "expires_at": expiry,
            }))
        }
        ProcessedPacketData::FinalHop {
            destination,
            payload,
            ..
        } => {
            let expected = decode_node_id(&encode_node_id(destination.as_bytes()))?;
            if expected != destination.as_bytes() {
                return Err("invalid_destination");
            }
            let plaintext = payload.recover_plaintext().map_err(|_| "invalid_final_payload")?;
            let (expiry_ms, final_payload) = decode_final_payload(&plaintext)?;
            Ok(json!({
                "next_node_id": null,
                "next_capability": null,
                "next_packet_b64": null,
                "final_payload_b64": URL_SAFE.encode(final_payload),
                "replay_tag_b64": URL_SAFE.encode(replay_tag),
                "expires_at": expiry_from_millis(expiry_ms)?,
            }))
        }
    }
}

fn encode_final_payload(expiry_ms: u64, payload: &[u8]) -> Result<Vec<u8>, &'static str> {
    let length = u32::try_from(payload.len()).map_err(|_| "payload_too_large")?;
    let mut result = Vec::with_capacity(20 + payload.len());
    result.extend_from_slice(FINAL_MAGIC);
    result.extend_from_slice(&expiry_ms.to_be_bytes());
    result.extend_from_slice(&length.to_be_bytes());
    result.extend_from_slice(payload);
    Ok(result)
}

fn decode_final_payload(value: &[u8]) -> Result<(u64, &[u8]), &'static str> {
    if value.len() < 20 || &value[..8] != FINAL_MAGIC {
        return Err("invalid_final_payload");
    }
    let expiry_ms = u64::from_be_bytes(value[8..16].try_into().map_err(|_| "invalid_final_payload")?);
    let length = u32::from_be_bytes(value[16..20].try_into().map_err(|_| "invalid_final_payload")?) as usize;
    if length == 0 || length > MAX_PAYLOAD || value.len() != 20 + length {
        return Err("invalid_final_payload");
    }
    Ok((expiry_ms, &value[20..]))
}

fn parse_expiry(value: &str) -> Result<DateTime<Utc>, &'static str> {
    DateTime::parse_from_rfc3339(value)
        .map(|time| time.with_timezone(&Utc))
        .map_err(|_| "invalid_expiry")
}

fn expiry_from_millis(value: u64) -> Result<String, &'static str> {
    let millis = i64::try_from(value).map_err(|_| "invalid_expiry")?;
    let time = DateTime::<Utc>::from_timestamp_millis(millis).ok_or("invalid_expiry")?;
    Ok(time.to_rfc3339_opts(SecondsFormat::Millis, true))
}

fn decode_exact_32(value: &str) -> Result<[u8; 32], &'static str> {
    let decoded = decode_b64(value, 32)?;
    decoded.try_into().map_err(|_| "invalid_key")
}

fn decode_b64(value: &str, maximum: usize) -> Result<Vec<u8>, &'static str> {
    let decoded = URL_SAFE.decode(value.as_bytes()).map_err(|_| "invalid_base64")?;
    if decoded.len() > maximum {
        return Err("value_too_large");
    }
    Ok(decoded)
}

fn decode_node_id(value: &str) -> Result<[u8; 32], &'static str> {
    let encoded = value.strip_prefix(NODE_ID_PREFIX).ok_or("invalid_node_id")?;
    if encoded.len() != 52 || encoded.bytes().any(|byte| !matches!(byte, b'a'..=b'z' | b'2'..=b'7')) {
        return Err("invalid_node_id");
    }
    let decoded = BASE32_NOPAD
        .decode(encoded.to_ascii_uppercase().as_bytes())
        .map_err(|_| "invalid_node_id")?;
    decoded.try_into().map_err(|_| "invalid_node_id")
}

fn encode_node_id(value: [u8; 32]) -> String {
    format!("{NODE_ID_PREFIX}{}", BASE32_NOPAD.encode(&value).to_ascii_lowercase())
}

fn valid_request_id(value: &str) -> bool {
    value.len() == 36
        && value.as_bytes().get(14) == Some(&b'4')
        && matches!(value.as_bytes().get(19), Some(b'8' | b'9' | b'a' | b'b' | b'A' | b'B'))
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}
