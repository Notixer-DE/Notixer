use crate::api::{ApiError, authenticate};
use axum::{
    Json,
    body::Bytes,
    extract::{
        Path, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use loco_rs::app::AppContext;
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{
    sync::{Mutex, Semaphore, broadcast, watch},
    time::{interval, timeout},
};
use uuid::Uuid;

const SESSION_AGE: Duration = Duration::from_secs(2 * 60 * 60);
const IO_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_MESSAGE: usize = 2 * 1024 * 1024;
const MAX_SPECTATORS: usize = 12;

#[derive(Clone)]
pub(crate) struct LiveRooms {
    rooms: Arc<Mutex<HashMap<String, Arc<Room>>>>,
    sockets: Arc<Semaphore>,
}

impl Default for LiveRooms {
    fn default() -> Self {
        Self {
            rooms: Default::default(),
            sockets: Arc::new(Semaphore::new(128)),
        }
    }
}

struct Room {
    owner: String,
    invite: [u8; 32],
    expires: Instant,
    publisher: watch::Sender<Option<Uuid>>,
    viewers: watch::Sender<usize>,
    ended: watch::Sender<bool>,
    frames: broadcast::Sender<Bytes>,
}

fn random_id() -> String {
    let mut bytes = [0_u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    hex::encode(bytes)
}

fn store(ctx: &AppContext) -> Result<LiveRooms, ApiError> {
    ctx.shared_store
        .get::<LiveRooms>()
        .ok_or(ApiError(StatusCode::SERVICE_UNAVAILABLE))
}

fn active(room: &Room) -> bool {
    room.expires > Instant::now() && !*room.ended.borrow()
}

pub(crate) async fn create(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
) -> Result<(HeaderMap, Json<Value>), ApiError> {
    let owner = authenticate(&ctx.db, &headers).await?.device;
    let store = store(&ctx)?;
    let mut rooms = store.rooms.lock().await;
    rooms.retain(|_, room| active(room));
    if rooms.len() >= 32 || rooms.values().filter(|room| room.owner == owner).count() >= 2 {
        return Err(ApiError(StatusCode::TOO_MANY_REQUESTS));
    }
    let id = random_id();
    let invite = random_id();
    let room = Arc::new(Room {
        owner,
        invite: Sha256::digest(invite.as_bytes()).into(),
        expires: Instant::now() + SESSION_AGE,
        publisher: watch::channel(None).0,
        viewers: watch::channel(0).0,
        ended: watch::channel(false).0,
        frames: broadcast::channel(8).0,
    });
    rooms.insert(id.clone(), Arc::clone(&room));
    let registry = Arc::clone(&store.rooms);
    let expired_id = id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(SESSION_AGE).await;
        if let Some(room) = registry.lock().await.remove(&expired_id) {
            room.ended.send_replace(true);
        }
    });
    let headers = [(header::CACHE_CONTROL, HeaderValue::from_static("no-store"))]
        .into_iter()
        .collect();
    Ok((headers, Json(json!({"id": id, "invite": invite}))))
}

pub(crate) async fn end(
    State(ctx): State<AppContext>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    let owner = authenticate(&ctx.db, &headers).await?.device;
    let store = store(&ctx)?;
    let mut rooms = store.rooms.lock().await;
    if let Some(room) = rooms.get(&id) {
        if room.owner != owner {
            return Err(ApiError(StatusCode::NOT_FOUND));
        }
        room.ended.send_replace(true);
        rooms.remove(&id);
    }
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn connect(
    State(ctx): State<AppContext>,
    Path(id): Path<String>,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    let store = store(&ctx)?;
    let permit = store
        .sockets
        .try_acquire_owned()
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE))?;
    let room = store
        .rooms
        .lock()
        .await
        .get(&id)
        .filter(|room| active(room))
        .cloned()
        .ok_or(ApiError(StatusCode::NOT_FOUND))?;
    Ok(ws
        .max_message_size(MAX_MESSAGE)
        .max_frame_size(MAX_MESSAGE)
        .on_upgrade(move |socket| async move {
            let _permit = permit;
            serve(socket, ctx, room).await;
        }))
}

#[derive(Deserialize)]
struct Join {
    role: String,
    token: String,
}

async fn send(socket: &mut WebSocket, message: Message) -> bool {
    matches!(timeout(IO_TIMEOUT, socket.send(message)).await, Ok(Ok(())))
}

async fn serve(mut socket: WebSocket, ctx: AppContext, room: Arc<Room>) {
    let Ok(Some(Ok(Message::Text(first)))) = timeout(IO_TIMEOUT, socket.recv()).await else {
        return;
    };
    let Ok(join) = serde_json::from_str::<Join>(first.as_str()) else {
        return;
    };
    let admitted = active(&room);
    if admitted
        && join.role == "host"
        && let Ok(token) = HeaderValue::from_str(&format!("Bearer {}", join.token))
    {
        let mut headers = HeaderMap::new();
        headers.insert(header::AUTHORIZATION, token);
        if timeout(IO_TIMEOUT, authenticate(&ctx.db, &headers))
            .await
            .is_ok_and(|result| result.is_ok_and(|identity| identity.device == room.owner))
            && active(&room)
        {
            let owner = Uuid::new_v4();
            room.publisher.send_replace(Some(owner));
            host(&mut socket, &room, owner).await;
            room.publisher.send_if_modified(|current| {
                if *current != Some(owner) {
                    return false;
                }
                *current = None;
                true
            });
            return;
        }
    } else if admitted && join.role == "viewer" && join.token.len() == 64 {
        let hash: [u8; 32] = Sha256::digest(join.token.as_bytes()).into();
        if hash == room.invite {
            let events = room.frames.subscribe();
            if room.viewers.send_if_modified(|count| {
                if *count >= MAX_SPECTATORS {
                    return false;
                }
                *count += 1;
                true
            }) {
                viewer(&mut socket, &room, events).await;
                room.viewers.send_modify(|count| *count -= 1);
                return;
            }
        }
    }
    send(&mut socket, Message::Text("denied".into())).await;
}

async fn host(socket: &mut WebSocket, room: &Room, owner: Uuid) {
    let mut publisher = room.publisher.subscribe();
    let mut ended = room.ended.subscribe();
    let mut viewers = room.viewers.subscribe();
    let mut heartbeat = interval(Duration::from_secs(20));
    loop {
        if *publisher.borrow_and_update() != Some(owner) {
            return;
        }
        if *ended.borrow() {
            send(socket, Message::Text("ended".into())).await;
            return;
        }
        let count = *viewers.borrow_and_update();
        if !send(
            socket,
            Message::Text(json!({"viewers": count}).to_string().into()),
        )
        .await
        {
            return;
        }
        loop {
            tokio::select! {
                _ = ended.changed() => break,
                _ = viewers.changed() => break,
                _ = publisher.changed() => break,
                _ = heartbeat.tick() => {
                    if !send(socket, Message::Ping(Bytes::new())).await { return; }
                }
                input = socket.recv() => match input {
                    Some(Ok(Message::Binary(frame)))
                        if !frame.is_empty() && *publisher.borrow() == Some(owner) => {
                        let _ = room.frames.send(frame);
                    }
                    Some(Ok(Message::Pong(_) | Message::Ping(_))) => {}
                    _ => return,
                },
            }
        }
    }
}

async fn viewer(socket: &mut WebSocket, room: &Room, mut events: broadcast::Receiver<Bytes>) {
    let mut ended = room.ended.subscribe();
    let mut publisher = room.publisher.subscribe();
    let mut heartbeat = interval(Duration::from_secs(20));
    if !send(socket, Message::Text("joined".into())).await {
        return;
    }
    loop {
        if *ended.borrow() {
            send(socket, Message::Text("ended".into())).await;
            return;
        }
        tokio::select! {
            _ = ended.changed() => {},
            _ = publisher.changed() => {
                let offline = publisher.borrow_and_update().is_none();
                if offline && !send(socket, Message::Text("host-offline".into())).await {
                    return;
                }
            }
            _ = heartbeat.tick() => {
                if !send(socket, Message::Ping(Bytes::new())).await { return; }
            }
            event = events.recv() => {
                let Ok(frame) = event else { return; };
                if !send(socket, Message::Binary(frame)).await { return; }
            }
            input = socket.recv() => match input {
                Some(Ok(Message::Pong(_) | Message::Ping(_))) => {}
                _ => return,
            },
        }
    }
}
