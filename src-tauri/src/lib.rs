use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, State};

const STREAM_EVENT: &str = "astra-http-stream";
const IDLE_TIMEOUT: Duration = Duration::from_secs(120);

type CancelHandles = Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>;

#[derive(Default, Clone)]
struct StreamState {
    handles: CancelHandles,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HttpRequestPayload {
    url: String,
    method: Option<String>,
    headers: Option<HashMap<String, String>>,
    body_base64: Option<String>,
    timeout_ms: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HttpResponsePayload {
    status: u16,
    status_text: String,
    headers: HashMap<String, String>,
    body_base64: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct StreamEvent {
    id: String,
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    status_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    headers: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

fn build_client(timeout_ms: Option<u64>) -> Result<reqwest::Client, String> {
    let mut builder = reqwest::Client::builder().user_agent("Astra/0.2.0");
    if let Some(ms) = timeout_ms {
        builder = builder.timeout(Duration::from_millis(ms));
    }
    builder.build().map_err(|error| error.to_string())
}

fn apply_request(
    client: &reqwest::Client,
    request: &HttpRequestPayload,
) -> Result<reqwest::RequestBuilder, String> {
    let method = reqwest::Method::from_bytes(
        request
            .method
            .as_deref()
            .unwrap_or("GET")
            .to_uppercase()
            .as_bytes(),
    )
    .map_err(|error| error.to_string())?;
    let mut builder = client.request(method, &request.url);
    if let Some(headers) = &request.headers {
        for (key, value) in headers {
            let name = reqwest::header::HeaderName::from_bytes(key.as_bytes())
                .map_err(|error| error.to_string())?;
            let value = reqwest::header::HeaderValue::from_str(value)
                .map_err(|error| error.to_string())?;
            builder = builder.header(name, value);
        }
    }
    if let Some(body) = &request.body_base64 {
        let bytes = STANDARD
            .decode(body)
            .map_err(|error| format!("Invalid request body: {error}"))?;
        builder = builder.body(bytes);
    }
    Ok(builder)
}

fn read_headers(headers: &reqwest::header::HeaderMap) -> HashMap<String, String> {
    let mut result = HashMap::new();
    for (name, value) in headers.iter() {
        if let Ok(text) = value.to_str() {
            result.insert(name.as_str().to_string(), text.to_string());
        }
    }
    result
}

fn canonical_status_text(response: &reqwest::Response) -> String {
    response
        .status()
        .canonical_reason()
        .unwrap_or_default()
        .to_string()
}

#[tauri::command]
async fn http_request(request: HttpRequestPayload) -> Result<HttpResponsePayload, String> {
    let client = build_client(request.timeout_ms)?;
    let builder = apply_request(&client, &request)?;
    let response = builder.send().await.map_err(|error| error.to_string())?;
    let status = response.status().as_u16();
    let status_text = canonical_status_text(&response);
    let headers = read_headers(response.headers());
    let bytes = response
        .bytes()
        .await
        .map_err(|error| error.to_string())?;
    Ok(HttpResponsePayload {
        status,
        status_text,
        headers,
        body_base64: STANDARD.encode(bytes),
    })
}

async fn run_stream(
    app: &AppHandle,
    request_id: &str,
    request: HttpRequestPayload,
    cancel: Arc<AtomicBool>,
) -> Result<(), String> {
    let client = build_client(None)?;
    let builder = apply_request(&client, &request)?;
    let response = builder.send().await.map_err(|error| error.to_string())?;
    let status = response.status().as_u16();
    let status_text = canonical_status_text(&response);
    let headers = read_headers(response.headers());
    app.emit(
        STREAM_EVENT,
        StreamEvent {
            id: request_id.to_string(),
            kind: "start",
            status: Some(status),
            status_text: Some(status_text),
            headers: Some(headers),
            data: None,
            message: None,
        },
    )
    .map_err(|error| error.to_string())?;

    let mut stream = response.bytes_stream();
    loop {
        if cancel.load(Ordering::SeqCst) {
            break;
        }
        match tokio::time::timeout(IDLE_TIMEOUT, stream.next()).await {
            Err(_) => return Err("Stream idle timeout".to_string()),
            Ok(None) => break,
            Ok(Some(Err(error))) => return Err(error.to_string()),
            Ok(Some(Ok(bytes))) => {
                app.emit(
                    STREAM_EVENT,
                    StreamEvent {
                        id: request_id.to_string(),
                        kind: "chunk",
                        status: None,
                        status_text: None,
                        headers: None,
                        data: Some(STANDARD.encode(bytes)),
                        message: None,
                    },
                )
                .map_err(|error| error.to_string())?;
            }
        }
    }
    app.emit(
        STREAM_EVENT,
        StreamEvent {
            id: request_id.to_string(),
            kind: "end",
            status: None,
            status_text: None,
            headers: None,
            data: None,
            message: None,
        },
    )
    .map_err(|error| error.to_string())?;
    Ok(())
}

#[tauri::command]
async fn http_stream(
    app: AppHandle,
    state: State<'_, StreamState>,
    request_id: String,
    request: HttpRequestPayload,
) -> Result<(), String> {
    let cancel = Arc::new(AtomicBool::new(false));
    state
        .handles
        .lock()
        .map_err(|error| error.to_string())?
        .insert(request_id.clone(), cancel.clone());
    let handles = state.handles.clone();
    let app_handle = app.clone();
    let id = request_id.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(message) = run_stream(&app_handle, &id, request, cancel).await {
            let _ = app_handle.emit(
                STREAM_EVENT,
                StreamEvent {
                    id: id.clone(),
                    kind: "error",
                    status: None,
                    status_text: None,
                    headers: None,
                    data: None,
                    message: Some(message),
                },
            );
        }
        if let Ok(mut map) = handles.lock() {
            map.remove(&id);
        }
    });
    Ok(())
}

#[tauri::command]
fn http_stream_abort(state: State<'_, StreamState>, request_id: String) -> Result<(), String> {
    if let Some(cancel) = state
        .handles
        .lock()
        .map_err(|error| error.to_string())?
        .get(&request_id)
    {
        cancel.store(true, Ordering::SeqCst);
    }
    Ok(())
}

#[tauri::command]
fn save_file(path: String, data_base64: String) -> Result<(), String> {
    let bytes = STANDARD
        .decode(data_base64)
        .map_err(|error| format!("Invalid file data: {error}"))?;
    std::fs::write(path, bytes).map_err(|error| error.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(StreamState::default())
        .invoke_handler(tauri::generate_handler![
            http_request,
            http_stream,
            http_stream_abort,
            save_file
        ])
        .run(tauri::generate_context!())
        .expect("error while running Astra");
}
