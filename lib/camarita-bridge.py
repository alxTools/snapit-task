from __future__ import annotations

import ctypes
import hashlib
import io
import json
import logging
import math
import os
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.request
import wave
import winsound
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path.home()
SNAPIT = HOME / ".snapit"
CONFIG_PATH = SNAPIT / "voice-config.json"
EVENT_DIR = SNAPIT / "voice-events"
LOG_PATH = SNAPIT / "logs" / "camarita-bridge.log"
# voice-flow.ps1 lives next to this bridge, wherever the repo was cloned.
# Override with the SNAPIT_ROOT environment variable, or with the
# "flow_script" key in voice-config.json, if you keep it somewhere else.
REPO_ROOT = Path(os.environ.get("SNAPIT_ROOT", str(Path(__file__).resolve().parent.parent)))
DEFAULT_FLOW_SCRIPT = REPO_ROOT / "lib" / "voice-flow.ps1"

SNAPIT.mkdir(exist_ok=True)
EVENT_DIR.mkdir(parents=True, exist_ok=True)
LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(filename=LOG_PATH, level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

if not CONFIG_PATH.exists():
    raise SystemExit(
        "Missing " + str(CONFIG_PATH) + " - copy voice-config.example.json there "
        "and fill in callback_token and camera_token."
    )

config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
CALLBACK_TOKEN = config["callback_token"]
CAMERA_TOKEN = config["camera_token"]
# Local-only defaults: point camera_api at your own service when you have one.
CAMERA_API = config.get("camera_api", "http://127.0.0.1:8765").rstrip("/")
BIND = config.get("bind", "127.0.0.1")
PORT = int(config.get("port", 8778))
ALERT_AMPLITUDE = float(config.get("alert_amplitude", 0.78))
FLOW_SCRIPT = Path(config.get("flow_script") or DEFAULT_FLOW_SCRIPT)

_seen: dict[str, float] = {}
_seen_lock = threading.Lock()


def _play_tones(tones: list[tuple[int, int]], pause_ms: int = 75) -> None:
    """Play amplified WAV tones through the active Windows output device."""
    rate = 48_000
    frames: list[bytes] = []
    for tone_index, (frequency, duration_ms) in enumerate(tones):
        samples = max(1, int(rate * duration_ms / 1000))
        fade = min(int(rate * 0.012), samples // 4)
        for index in range(samples):
            envelope = 1.0
            if fade:
                if index < fade:
                    envelope = index / fade
                elif index >= samples - fade:
                    envelope = (samples - 1 - index) / fade
            sample = int(32767 * ALERT_AMPLITUDE * envelope * math.sin(2 * math.pi * frequency * index / rate))
            frames.append(struct.pack('<h', sample))
        if tone_index < len(tones) - 1:
            frames.extend([b'\x00\x00'] * int(rate * pause_ms / 1000))
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(b''.join(frames))
    winsound.PlaySound(buffer.getvalue(), winsound.SND_MEMORY)


def beep_ready() -> None:
    """Two rising tones: activation accepted; start speaking now."""
    try:
        _play_tones([(880, 220), (1175, 360)], pause_ms=90)
    except RuntimeError:
        winsound.MessageBeep()


def beep_sent() -> None:
    """Three bright tones: command callback received and handoff launched."""
    try:
        _play_tones([(1319, 180), (1568, 180), (2093, 460)], pause_ms=75)
    except RuntimeError:
        winsound.MessageBeep()


def api_post(path: str) -> None:
    req = urllib.request.Request(
        CAMERA_API + path,
        data=b"{}",
        method="POST",
        headers={"Authorization": f"Bearer {CAMERA_TOKEN}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=8) as response:
        if response.status >= 300:
            raise RuntimeError(f"camera API returned {response.status}")


def event_key(payload: dict) -> str:
    stable = json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(stable).hexdigest()


def launch_voice_flow(payload: dict) -> None:
    key = event_key(payload)
    now = time.time()
    with _seen_lock:
        for old, stamp in list(_seen.items()):
            if now - stamp > 300:
                _seen.pop(old, None)
        if key in _seen:
            logging.info("duplicate command ignored %s", key[:12])
            return
        _seen[key] = now
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = EVENT_DIR / f"{stamp}-{key[:8]}.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    subprocess.Popen(
        [
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", str(FLOW_SCRIPT), "-EventFile", str(path),
        ],
        cwd=str(FLOW_SCRIPT.parent.parent),
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    logging.info("voice flow launched profile=%s sensitive=%s", payload.get("target_profile"), payload.get("requires_confirmation"))


class Handler(BaseHTTPRequestHandler):
    server_version = "CamaritaBridge/1.0"

    def log_message(self, fmt: str, *args) -> None:
        logging.info("http " + fmt, *args)

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._json(200, {"status": "ok", "hotkey": "Ctrl+Alt+Space (hold)"})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/events":
            self._json(404, {"error": "not found"})
            return
        if self.headers.get("X-Camarita-Token", "") != CALLBACK_TOKEN:
            self._json(401, {"error": "unauthorized"})
            return
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 65536)
            payload = json.loads(self.rfile.read(length) or b"{}")
            event = payload.get("event")
            if event == "voice.activated":
                beep_ready()
            elif event == "voice.command.ready":
                launch_voice_flow(payload)
                beep_sent()
            self._json(200, {"accepted": True, "event": event})
        except Exception as exc:
            logging.exception("event failed")
            self._json(400, {"error": str(exc)[:200]})


def hotkey_loop() -> None:
    user32 = ctypes.windll.user32
    VK_CONTROL, VK_MENU, VK_SPACE = 0x11, 0x12, 0x20
    held = False
    while True:
        now_held = all(user32.GetAsyncKeyState(vk) & 0x8000 for vk in (VK_CONTROL, VK_MENU, VK_SPACE))
        if now_held and not held:
            try:
                api_post("/v1/voice/hotkey/start")
                logging.info("hotkey start")
            except Exception:
                logging.exception("hotkey start failed")
        elif held and not now_held:
            try:
                api_post("/v1/voice/hotkey/stop")
                logging.info("hotkey stop")
            except Exception:
                logging.exception("hotkey stop failed")
        held = now_held
        time.sleep(0.04)


def main() -> None:
    threading.Thread(target=hotkey_loop, name="camarita-hotkey", daemon=True).start()
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    logging.info("bridge listening on %s:%s", BIND, PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
