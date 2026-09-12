#!/usr/bin/env python3
"""
scrcpy_stream.py — multi-emulator scrcpy client + browser streamer

Streams every connected adb device to one browser page, side by side.
Each device gets its own scrcpy server, port forward, and WebSocket route.

Run:
    python3 scrcpy_stream.py
    open http://localhost:3200
"""
import os
import json
import random
import asyncio
import struct
import traceback
from pathlib import Path
from aiohttp import web, WSMsgType

ADB        = "adb"
PORT       = int(os.getenv("PORT", "3200"))
MAX_SIZE   = os.getenv("MAX_SIZE", "480")     # smaller = less CPU with 5 streams
MAX_FPS    = os.getenv("MAX_FPS", "20")
BIT_RATE   = os.getenv("BIT_RATE", "2000000")
SERVER_VER = os.getenv("SERVER_VER", "3.1")
DEBUG      = os.getenv("DEBUG", "") == "1"

# Optional: limit to specific devices
DEVICES_ENV = os.getenv("DEVICES", "").strip()

JAR_PATH = Path("/tmp/scrcpy-server.jar")
JAR_URL  = f"https://github.com/Genymobile/scrcpy/releases/download/v{SERVER_VER}/scrcpy-server-v{SERVER_VER}"

CTRL_KEYCODE = 0
CTRL_TEXT    = 1
CTRL_TOUCH   = 2
ACTION_DOWN = 0
ACTION_UP   = 1
ACTION_MOVE = 2
PRESSURE_MAX   = 0xFFFF
BUTTON_PRIMARY = 1


def encode_touch(x, y, w, h, action, pointer_id=0, pressure=None):
    if pressure is None:
        pressure = 0 if action == ACTION_UP else 1
    p = max(0, min(PRESSURE_MAX, int(pressure * PRESSURE_MAX)))
    buf = bytearray(32)
    buf[0] = CTRL_TOUCH
    buf[1] = action
    struct.pack_into(">Q", buf, 2,  pointer_id)
    struct.pack_into(">i", buf, 10, int(x))
    struct.pack_into(">i", buf, 14, int(y))
    struct.pack_into(">H", buf, 18, int(w))
    struct.pack_into(">H", buf, 20, int(h))
    struct.pack_into(">H", buf, 22, p)
    struct.pack_into(">I", buf, 24, BUTTON_PRIMARY)
    struct.pack_into(">I", buf, 28, 0 if action == ACTION_UP else BUTTON_PRIMARY)
    return bytes(buf)


def encode_key(keycode, action):
    buf = bytearray(14)
    buf[0] = CTRL_KEYCODE
    buf[1] = action
    struct.pack_into(">i", buf, 2, int(keycode))
    return bytes(buf)


def encode_text(text):
    payload = text.encode("utf-8")
    buf = bytearray(5 + len(payload))
    buf[0] = CTRL_TEXT
    struct.pack_into(">I", buf, 1, len(payload))
    buf[5:] = payload
    return bytes(buf)


def find_sps(annexb):
    i = 0
    n = len(annexb)
    while i < n - 3:
        if annexb[i:i+4] == b"\x00\x00\x00\x01":
            off = i + 4
        elif annexb[i:i+3] == b"\x00\x00\x01":
            off = i + 3
        else:
            i += 1
            continue
        if off >= n:
            break
        if (annexb[off] & 0x1F) == 7 and off + 4 <= n:
            return annexb[off+1], annexb[off+2], annexb[off+3]
        i = off
    return None


async def list_devices():
    """Return serials of all adb devices in 'device' state, deduped."""
    p = await asyncio.create_subprocess_exec(
        ADB, "devices",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, _ = await p.communicate()
    serials = []
    for line in out.decode("utf-8", "ignore").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])

    # dedupe: prefer emulator-XXXX over localhost:YYYY where both point to same device
    emus = [s for s in serials if s.startswith("emulator-")]
    locals_ = [s for s in serials if s.startswith("localhost:")]
    others = [s for s in serials if s not in emus and s not in locals_]
    # if we have the emulator-XXXX form, drop localhost:YYYY duplicates
    if emus:
        serials = emus + others
    else:
        serials = locals_ + others
    return serials


class ScrcpySession:
    def __init__(self, device_id):
        self.device_id    = device_id
        self.scid         = random.randint(1, 0x7FFFFFFF)
        self.forward_port = random.randint(27183, 27399)
        self.proc         = None
        self.video_rd     = None
        self.video_wr     = None
        self.control_rd   = None
        self.control_wr   = None
        self.device_name  = device_id
        self.width        = 0
        self.height       = 0
        self.codec_string = "avc1.42E01E"
        self._clock       = asyncio.Lock()
        self._stdout_task = None
        self._stderr_task = None
        self._subscribers = set()
        self._reader_task = None
        self._running     = False
        self.packet_count = 0
        self._cached_config   = None
        self._cached_keyframe = None

    def tag(self):
        return f"[{self.device_id}]"

    async def _adb(self, *args, timeout=30):
        cmd = [ADB, "-s", self.device_id] + list(args)
        if DEBUG:
            print(f"  {self.tag()} [adb] {' '.join(cmd)}")
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            return proc.returncode, out.decode("utf-8", "ignore"), err.decode("utf-8", "ignore")
        except asyncio.TimeoutError:
            proc.kill()
            return -1, "", "timeout"

    async def check_device(self):
        rc, out, err = await self._adb("shell", "echo", "ok", timeout=8)
        if rc != 0 or "ok" not in out:
            raise RuntimeError(f"not responding")
        print(f"  {self.tag()} responds")

    async def wake_screen(self):
        await self._adb("shell", "input", "keyevent", "KEYCODE_WAKEUP", timeout=5)
        await self._adb("shell", "wm", "dismiss-keyguard", timeout=5)

    async def cleanup(self):
        await self._adb("shell", "pkill -f com.genymobile.scrcpy.Server", timeout=5)
        await asyncio.sleep(0.4)

    async def ensure_jar(self):
        if JAR_PATH.exists() and JAR_PATH.stat().st_size > 10_000:
            return
        print(f"  downloading {JAR_URL}")
        proc = await asyncio.create_subprocess_exec(
            "curl", "-L", "-s", "-o", str(JAR_PATH), JAR_URL,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        if not JAR_PATH.exists() or JAR_PATH.stat().st_size < 10_000:
            raise RuntimeError("jar download failed")

    async def push_jar(self):
        rc, _, err = await self._adb("push", str(JAR_PATH),
                                     "/data/local/tmp/scrcpy-server.jar")
        if rc != 0:
            raise RuntimeError(f"push failed: {err.strip()}")

    async def setup_forward(self):
        abstract = f"scrcpy_{self.scid:08x}"
        rc, _, err = await self._adb(
            "forward", f"tcp:{self.forward_port}", f"localabstract:{abstract}")
        if rc != 0:
            raise RuntimeError(f"forward failed: {err.strip()}")
        print(f"  {self.tag()} forward :{self.forward_port} -> {abstract}")

    async def start_server(self):
        args = [
            SERVER_VER,
            f"scid={self.scid:08x}",
            "log_level=info",
            f"max_size={MAX_SIZE}",
            f"max_fps={MAX_FPS}",
            f"video_bit_rate={BIT_RATE}",
            "tunnel_forward=true",
            "audio=false",
            "control=true",
            "cleanup=true",
        ]
        cmd = ("CLASSPATH=/data/local/tmp/scrcpy-server.jar "
               "app_process / com.genymobile.scrcpy.Server " + " ".join(args))
        self.proc = await asyncio.create_subprocess_exec(
            ADB, "-s", self.device_id, "shell", cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        if DEBUG:
            self._stdout_task = asyncio.create_task(self._pump(self.proc.stdout, "out"))
        self._stderr_task = asyncio.create_task(self._pump(self.proc.stderr, "err"))
        await asyncio.sleep(2.0)

    async def _pump(self, stream, tag):
        try:
            while True:
                line = await stream.readline()
                if not line:
                    break
                text = line.decode("utf-8", "ignore").rstrip()
                if text and DEBUG:
                    print(f"  {self.tag()} [{tag}] {text}")
        except Exception:
            pass

    async def connect_video(self):
        for _ in range(40):
            try:
                self.video_rd, self.video_wr = await asyncio.open_connection(
                    "127.0.0.1", self.forward_port)
                print(f"  {self.tag()} video connected")
                return
            except (ConnectionRefusedError, OSError):
                await asyncio.sleep(0.3)
        raise RuntimeError("video connect failed")

    async def connect_control(self):
        for _ in range(40):
            try:
                self.control_rd, self.control_wr = await asyncio.open_connection(
                    "127.0.0.1", self.forward_port)
                print(f"  {self.tag()} control connected")
                return
            except (ConnectionRefusedError, OSError):
                await asyncio.sleep(0.3)
        raise RuntimeError("control connect failed")

    @staticmethod
    async def _read_exact(reader, n, timeout=None):
        async def _do():
            buf = bytearray()
            while len(buf) < n:
                chunk = await reader.read(n - len(buf))
                if not chunk:
                    raise EOFError(f"EOF after {len(buf)}/{n} bytes")
                buf.extend(chunk)
            return bytes(buf)
        if timeout is None:
            return await _do()
        return await asyncio.wait_for(_do(), timeout=timeout)

    async def read_metadata(self):
        await self._read_exact(self.video_rd, 1, timeout=25)
        raw = await self._read_exact(self.video_rd, 64, timeout=25)
        self.device_name = raw.rstrip(b"\x00").decode("utf-8", "ignore")
        meta = await self._read_exact(self.video_rd, 12, timeout=10)
        codec_id, width, height = struct.unpack(">III", meta)
        if width < 0:  width = -width
        if height < 0: height = -height
        self.width, self.height = width, height
        codec = {0x68323634: "h264", 0x68323635: "h265",
                 0x00617631: "av1"}.get(codec_id, f"0x{codec_id:08x}")
        print(f"  {self.tag()} {self.device_name!r}  {codec}  {width}x{height}")

    async def next_packet(self):
        header = await self._read_exact(self.video_rd, 12, timeout=None)
        pts_flags, size = struct.unpack(">QI", header)
        is_config = bool(pts_flags & (1 << 63))
        is_key    = bool(pts_flags & (1 << 62))
        if size == 0:
            return {"config": is_config, "key": is_key, "payload": b"", "skip": True}
        payload = await self._read_exact(self.video_rd, size, timeout=None)
        return {"config": is_config, "key": is_key, "payload": payload, "skip": False}

    async def send_control(self, data):
        async with self._clock:
            if not self.control_wr:
                return
            self.control_wr.write(data)
            await self.control_wr.drain()

    def subscribe(self):
        q = asyncio.Queue(maxsize=512)
        self._subscribers.add(q)
        if self._cached_config:
            try: q.put_nowait(self._cached_config)
            except Exception: pass
        if self._cached_keyframe:
            try: q.put_nowait(self._cached_keyframe)
            except Exception: pass
        return q

    def unsubscribe(self, q):
        self._subscribers.discard(q)

    async def _reader_loop(self):
        snf_done = False
        while self._running:
            try:
                pkt = await self.next_packet()
            except asyncio.CancelledError:
                break
            except Exception as e:
                print(f"  {self.tag()} reader: {type(e).__name__}: {e!r}")
                break
            if pkt.get("skip"):
                continue
            self.packet_count += 1
            if pkt["config"] and not snf_done:
                sps = find_sps(pkt["payload"])
                if sps:
                    p, c, l = sps
                    self.codec_string = f"avc1.{p:02X}{c:02X}{l:02X}"
                    print(f"  {self.tag()} codec -> {self.codec_string}")
                snf_done = True
            flags = 0
            if pkt["key"]:    flags |= 0x01
            if pkt["config"]: flags |= 0x02
            data = bytes([flags]) + pkt["payload"]
            if pkt["config"]:
                self._cached_config = data
            elif pkt["key"]:
                self._cached_keyframe = data
            for q in list(self._subscribers):
                try:
                    q.put_nowait(data)
                except asyncio.QueueFull:
                    try: q.get_nowait()
                    except Exception: pass
                    try: q.put_nowait(data)
                    except Exception: pass

    def start_broadcast(self):
        self._running = True
        self._reader_task = asyncio.create_task(self._reader_loop())

    async def start(self):
        await self.check_device()
        await self.wake_screen()
        await self.cleanup()
        await self.ensure_jar()
        await self.push_jar()
        await self.setup_forward()
        await self.start_server()
        await self.connect_video()
        await self.connect_control()
        await self.read_metadata()
        self.start_broadcast()
        print(f"  {self.tag()} ready")

    async def stop(self):
        self._running = False
        if self._reader_task:
            self._reader_task.cancel()
        for w in (self.video_wr, self.control_wr):
            if w:
                try: w.close()
                except Exception: pass
        if self.proc:
            try: self.proc.kill()
            except Exception: pass
        try:
            await self._adb("forward", "--remove", f"tcp:{self.forward_port}")
        except Exception:
            pass


# ------------------------------------------------------------------
#  Session registry
# ------------------------------------------------------------------
_sessions = {}                 # device_id -> ScrcpySession
_sessions_lock = asyncio.Lock()
_known_devices = []            # cache of last-detected serials


async def get_session(device_id):
    async with _sessions_lock:
        s = _sessions.get(device_id)
        if s is None or not s._running:
            if s is not None:
                try: await s.stop()
                except Exception: pass
            s = ScrcpySession(device_id)
            try:
                await s.start()
            except Exception as e:
                print(f"  [{device_id}] failed: {e}")
                traceback.print_exc()
                raise
            _sessions[device_id] = s
        return s


async def detect_devices():
    global _known_devices
    if DEVICES_ENV:
        _known_devices = [d.strip() for d in DEVICES_ENV.split(",") if d.strip()]
    else:
        _known_devices = await list_devices()
    return _known_devices


# ------------------------------------------------------------------
#  HTTP + WS
# ------------------------------------------------------------------
async def index(request):
    return web.Response(text=INDEX, content_type="text/html", charset="utf-8")


async def api_devices(request):
    devices = await detect_devices()
    return web.json_response({"devices": devices})


async def ws_handler(request):
    device_id = request.match_info["device"]

    ws = web.WebSocketResponse(max_msg_size=0, heartbeat=30)
    await ws.prepare(request)

    try:
        session = await get_session(device_id)
    except Exception as e:
        try:
            await ws.send_str(json.dumps({"type": "error", "message": str(e)}))
        except Exception:
            pass
        await ws.close()
        return ws

    await ws.send_str(json.dumps({
        "type": "meta",
        "device": session.device_name,
        "device_id": device_id,
        "width": session.width,
        "height": session.height,
        "codec": session.codec_string,
    }))

    # wait for ready
    try:
        while True:
            msg = await asyncio.wait_for(ws.receive(), timeout=15)
            if msg.type == WSMsgType.TEXT and '"ready"' in msg.data:
                break
            if msg.type == WSMsgType.CLOSE:
                await ws.close(); return ws
    except asyncio.TimeoutError:
        await ws.close(); return ws

    q = session.subscribe()
    running = True

    async def pump():
        nonlocal running
        while running and not ws.closed:
            try:
                data = await q.get()
            except asyncio.CancelledError:
                break
            try:
                await ws.send_bytes(data)
            except Exception:
                break

    async def recv():
        nonlocal running
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try: d = json.loads(msg.data)
                except Exception: continue
                t = d.get("type")
                try:
                    if t == "tap":
                        await session.send_control(encode_touch(
                            d["x"], d["y"], session.width, session.height, ACTION_DOWN))
                        await session.send_control(encode_touch(
                            d["x"], d["y"], session.width, session.height, ACTION_UP))
                    elif t == "swipe":
                        x1, y1, x2, y2 = d["x1"], d["y1"], d["x2"], d["y2"]
                        await session.send_control(encode_touch(
                            x1, y1, session.width, session.height, ACTION_DOWN))
                        for i in range(1, 8):
                            ix = x1 + (x2 - x1) * i / 8
                            iy = y1 + (y2 - y1) * i / 8
                            await session.send_control(encode_touch(
                                ix, iy, session.width, session.height, ACTION_MOVE))
                        await session.send_control(encode_touch(
                            x2, y2, session.width, session.height, ACTION_UP))
                    elif t == "key":
                        code = int(d.get("code", 4))
                        await session.send_control(encode_key(code, ACTION_DOWN))
                        await session.send_control(encode_key(code, ACTION_UP))
                    elif t == "text":
                        await session.send_control(encode_text(str(d.get("text", ""))))
                except Exception as e:
                    print(f"  control: {e}")
            elif msg.type == WSMsgType.CLOSE:
                running = False
                break

    await asyncio.gather(pump(), recv(), return_exceptions=True)
    running = False
    session.unsubscribe(q)
    return ws


async def on_shutdown(app):
    for s in list(_sessions.values()):
        try: await s.stop()
        except Exception: pass
    _sessions.clear()


# ------------------------------------------------------------------
#  HTML
# ------------------------------------------------------------------
INDEX = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>CLAWTANK // STREAM</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Press+Start+2P&family=VT323&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box}*{margin:0;padding:0}
html,body{height:100%;overflow:hidden;background:#f2efe8}
body{font-family:'VT323',monospace;font-size:20px;color:#1a1816;display:flex;flex-direction:column}
body::after{content:"";position:fixed;inset:0;pointer-events:none;z-index:9998;
  background:repeating-linear-gradient(to bottom,rgba(26,24,22,.06) 0 1px,transparent 1px 3px)}
header{flex-shrink:0;display:flex;align-items:center;gap:1rem;padding:.6rem 1rem;
  border-bottom:2px solid #cfc7b8;background:linear-gradient(180deg,#fff,#f0ece2);z-index:2}
.brand{font-family:'Press Start 2P',monospace;font-size:.75rem;letter-spacing:.12em}
.hspacer{flex:1}
.hint{font-family:'Press Start 2P',monospace;font-size:.5rem;color:#6b6357;letter-spacing:.08em}

.stage{flex:1;display:flex;gap:1.25rem;align-items:center;justify-content:center;
  overflow:auto;padding:1rem;min-height:0;flex-wrap:nowrap}

.slot{display:flex;flex-direction:column;align-items:center;gap:.6rem;height:100%}
.slot-label{font-family:'Press Start 2P',monospace;font-size:.5rem;letter-spacing:.08em;color:#6b6357}

.phone{position:relative;height:100%;aspect-ratio:300/620;padding:5px;border-radius:46px;flex-shrink:0;
  background:linear-gradient(160deg,#f8f7f4 0%,#d6d2c8 14%,#b8b3a7 45%,#a09a8d 62%,#cfcabe 86%,#f0eee9 100%);
  box-shadow:0 0 0 2px #8a8377,0 0 0 4px #b8b3a7,0 20px 50px rgba(26,24,22,.25)}
.bezel{position:relative;width:100%;height:100%;border-radius:42px;background:#08060a;padding:12px}
.island{position:absolute;top:20px;left:50%;transform:translateX(-50%);
  width:80px;height:26px;background:#000;border-radius:999px;z-index:10}
.island::before{content:"";position:absolute;top:50%;right:14px;transform:translateY(-50%);
  width:8px;height:8px;border-radius:50%;background:#04040a}
.island::after{content:"";position:absolute;top:50%;left:14px;transform:translateY(-50%);
  width:28px;height:4px;background:#0a0a12;border-radius:2px}
.screen{position:relative;width:100%;height:100%;overflow:hidden;border-radius:30px;
  background:#0b0805;display:flex;align-items:center;justify-content:center}
.screen canvas{display:block;width:100%;height:100%;cursor:crosshair;touch-action:none}
.home-bar{position:absolute;bottom:6px;left:50%;transform:translateX(-50%);
  width:80px;height:4px;border-radius:3px;background:rgba(255,234,203,.55);z-index:8;pointer-events:none}

.slot-foot{display:flex;gap:.4rem;flex-wrap:wrap;justify-content:center}
.slot-foot button{font-family:'Press Start 2P',monospace;font-size:.45rem;letter-spacing:.06em;
  padding:.4rem .5rem;border:2px solid #cfc7b8;background:#fff;color:#1a1816;cursor:pointer;
  text-transform:uppercase}
.slot-foot button:hover{background:#d95f0e;color:#fff}

.pill{display:inline-flex;align-items:center;gap:.5rem;
  font-family:'Press Start 2P',monospace;font-size:.5rem;letter-spacing:.08em;
  padding:.4rem .6rem;border:2px solid #cfc7b8;background:#fff;color:#6b6357}
.pill .dot{width:8px;height:8px;border-radius:50%;background:#b03a2e}
.pill.on .dot{background:#3f8c25}
.pill.on{color:#3f8c25;border-color:rgba(63,140,37,.5)}
</style>
</head>
<body>
<header>
  <span class="brand">CLAWTANK</span>
  <span class="hspacer"></span>
  <span class="hint" id="hint">loading devices…</span>
</header>

<div class="stage" id="stage"></div>

<script>
function DeviceView(deviceId) {
  this.id = deviceId;
  this.ws = null;
  this.decoder = null;
  this.nativeW = 720;
  this.nativeH = 1560;
  this.configured = false;
  this.ts = 0;
  this.lastConfig = null;
  this.pendingBinary = [];
  this.frameCount = 0;
  this.fpsT = performance.now();
  this.drag = null;
  this.build();
  this.connect();
}

DeviceView.prototype.build = function() {
  var slot = document.createElement("div");
  slot.className = "slot";

  var label = document.createElement("div");
  label.className = "slot-label";
  label.textContent = this.id;
  slot.appendChild(label);

  var phone = document.createElement("div");
  phone.className = "phone";
  var bezel = document.createElement("div");
  bezel.className = "bezel";
  var island = document.createElement("div");
  island.className = "island";
  bezel.appendChild(island);
  var screen = document.createElement("div");
  screen.className = "screen";
  var canvas = document.createElement("canvas");
  canvas.width = 720; canvas.height = 1560;
  screen.appendChild(canvas);
  bezel.appendChild(screen);
  phone.appendChild(bezel);
  var homeBar = document.createElement("span");
  homeBar.className = "home-bar";
  phone.appendChild(homeBar);
  slot.appendChild(phone);

  var foot = document.createElement("div");
  foot.className = "slot-foot";
  var pill = document.createElement("span");
  pill.className = "pill";
  var dot = document.createElement("span");
  dot.className = "dot";
  var txt = document.createElement("span");
  txt.textContent = "connecting";
  pill.appendChild(dot); pill.appendChild(txt);
  foot.appendChild(pill);

  var self = this;
  function mkBtn(text, code) {
    var b = document.createElement("button");
    b.textContent = text;
    b.onclick = function() { self.send({type:"key", code:code}); };
    return b;
  }
  foot.appendChild(mkBtn("HOME", 3));
  foot.appendChild(mkBtn("BACK", 4));
  foot.appendChild(mkBtn("RECENTS", 187));
  var recon = document.createElement("button");
  recon.textContent = "RELOAD";
  recon.onclick = function() { if (self.ws) try { self.ws.close(); } catch(e){} };
  foot.appendChild(recon);

  slot.appendChild(foot);
  document.getElementById("stage").appendChild(slot);

  this.canvas = canvas;
  this.ctx = canvas.getContext("2d");
  this.pill = pill;
  this.pillText = txt;
  this.wireInput();
};

DeviceView.prototype.setStatus = function(text, on) {
  this.pillText.textContent = text;
  this.pill.classList.toggle("on", !!on);
};

DeviceView.prototype.makeDecoder = function() {
  var self = this;
  return new VideoDecoder({
    output: function(f) {
      if (f.displayWidth !== self.nativeW || f.displayHeight !== self.nativeH) {
        self.nativeW = f.displayWidth;
        self.nativeH = f.displayHeight;
        self.canvas.width = self.nativeW;
        self.canvas.height = self.nativeH;
      }
      self.ctx.drawImage(f, 0, 0, self.canvas.width, self.canvas.height);
      f.close();
      self.frameCount++;
      var now = performance.now();
      if (now - self.fpsT > 1000) {
        self.pillText.textContent = self.frameCount + " fps";
        self.frameCount = 0;
        self.fpsT = now;
      }
    },
    error: function(e) { console.error(self.id, "decode", e); }
  });
};

DeviceView.prototype.configureDecoder = async function(preferred) {
  var candidates = [];
  if (preferred) candidates.push(preferred);
  ["avc1.64001F","avc1.640028","avc1.4D401F","avc1.4D401E",
   "avc1.42E01F","avc1.42E01E","avc1.42C029"]
    .forEach(function(c){ if (candidates.indexOf(c) === -1) candidates.push(c); });
  for (var i = 0; i < candidates.length; i++) {
    var codec = candidates[i];
    var cfg = { codec: codec, codedWidth: this.nativeW, codedHeight: this.nativeH,
                optimizeForLatency: true };
    try {
      var support = await VideoDecoder.isConfigSupported(cfg);
      if (support.supported) {
        this.decoder.configure(cfg);
        this.configured = true;
        console.log(this.id, "codec", codec);
        return codec;
      }
    } catch (e) {}
  }
  return null;
};

DeviceView.prototype.feedChunk = function(buf) {
  if (buf.length < 2) return;
  var flags = buf[0];
  var isKey = (flags & 1) !== 0;
  var isCfg = (flags & 2) !== 0;
  var payload = buf.subarray(1);
  if (isCfg) { this.lastConfig = payload; return; }
  var data = payload;
  if (isKey && this.lastConfig && this.lastConfig.length) {
    data = new Uint8Array(this.lastConfig.length + payload.length);
    data.set(this.lastConfig, 0);
    data.set(payload, this.lastConfig.length);
  }
  this.ts += 33333;
  try {
    this.decoder.decode(new EncodedVideoChunk({
      type: isKey ? "key" : "delta",
      timestamp: this.ts,
      data: data
    }));
  } catch (e) { console.error(this.id, "feed", e); }
};

DeviceView.prototype.drainPending = function() {
  var arr = this.pendingBinary; this.pendingBinary = [];
  for (var i = 0; i < arr.length; i++) this.feedChunk(arr[i]);
};

DeviceView.prototype.connect = function() {
  var self = this;
  var p = location.protocol === "https:" ? "wss:" : "ws:";
  this.ws = new WebSocket(p + "//" + location.host + "/ws/" + encodeURIComponent(this.id));
  this.ws.binaryType = "arraybuffer";

  this.ws.onopen = function() {
    if (self.decoder) try { self.decoder.close(); } catch(e){}
    self.decoder = self.makeDecoder();
    self.configured = false;
    self.lastConfig = null;
    self.pendingBinary = [];
    self.setStatus("waiting", false);
  };
  this.ws.onclose = function() {
    self.setStatus("reconnecting", false);
    setTimeout(function(){ self.connect(); }, 1500);
  };
  this.ws.onerror = function() { self.setStatus("error", false); };
  this.ws.onmessage = async function(ev) {
    if (typeof ev.data === "string") {
      try {
        var m = JSON.parse(ev.data);
        if (m.type === "meta") {
          self.nativeW = m.width || self.nativeW;
          self.nativeH = m.height || self.nativeH;
          self.canvas.width = self.nativeW;
          self.canvas.height = self.nativeH;
          var used = await self.configureDecoder(m.codec || null);
          if (used) {
            self.setStatus("live", true);
            self.ws.send(JSON.stringify({type:"ready"}));
            self.drainPending();
          } else {
            self.setStatus("no codec", false);
          }
        } else if (m.type === "error") {
          self.setStatus("err", false);
        }
      } catch(e){}
      return;
    }
    var buf = new Uint8Array(ev.data);
    if (!self.configured) {
      self.pendingBinary.push(buf);
      if (self.pendingBinary.length > 512) self.pendingBinary.shift();
      return;
    }
    self.feedChunk(buf);
  };
};

DeviceView.prototype.toDev = function(cx, cy) {
  var r = this.canvas.getBoundingClientRect();
  return {
    x: Math.max(0, Math.min(this.nativeW - 1, (cx - r.left) / r.width * this.nativeW)),
    y: Math.max(0, Math.min(this.nativeH - 1, (cy - r.top) / r.height * this.nativeH))
  };
};

DeviceView.prototype.send = function(o) {
  if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(o));
};

DeviceView.prototype.wireInput = function() {
  var self = this;
  var cv = this.canvas;
  cv.addEventListener("mousedown", function(e){ self.drag = self.toDev(e.clientX, e.clientY); });
  cv.addEventListener("mouseup", function(e){
    if (!self.drag) return;
    var p = self.toDev(e.clientX, e.clientY);
    if (Math.abs(p.x-self.drag.x) > 25 || Math.abs(p.y-self.drag.y) > 25)
      self.send({type:"swipe", x1:self.drag.x, y1:self.drag.y, x2:p.x, y2:p.y});
    else
      self.send({type:"tap", x:self.drag.x, y:self.drag.y});
    self.drag = null;
  });
  cv.addEventListener("touchstart", function(e){
    e.preventDefault();
    var t = e.touches[0];
    self.drag = self.toDev(t.clientX, t.clientY);
  }, {passive:false});
  cv.addEventListener("touchend", function(e){
    e.preventDefault();
    if (!self.drag) return;
    var t = e.changedTouches[0];
    var p = self.toDev(t.clientX, t.clientY);
    if (Math.abs(p.x-self.drag.x) > 25 || Math.abs(p.y-self.drag.y) > 25)
      self.send({type:"swipe", x1:self.drag.x, y1:self.drag.y, x2:p.x, y2:p.y});
    else
      self.send({type:"tap", x:self.drag.x, y:self.drag.y});
    self.drag = null;
  }, {passive:false});
};

async function boot() {
  try {
    var r = await fetch("/api/devices");
    var d = await r.json();
    var devices = d.devices || [];
    document.getElementById("hint").textContent = devices.length + " device(s)";
    if (!devices.length) {
      document.getElementById("stage").innerHTML =
        '<div style="font-family:monospace;color:#b03a2e">No adb devices found. Run <code>adb devices</code> and refresh.</div>';
      return;
    }
    devices.forEach(function(id) { new DeviceView(id); });
  } catch (e) {
    document.getElementById("hint").textContent = "load failed";
  }
}
boot();
</script>
</body>
</html>"""


def main():
    print("")
    print(f"  port       : {PORT}")
    print(f"  size       : {MAX_SIZE}")
    print(f"  fps        : {MAX_FPS}")
    print(f"  bitrate    : {BIT_RATE}")
    print(f"  devices    : {DEVICES_ENV or 'auto-detect from adb'}")
    print(f"  server     : http://localhost:{PORT}")
    print("")
    print("  Open http://localhost:3200 — every adb device becomes a phone frame.")
    print("")

    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/api/devices", api_devices)
    app.router.add_get("/ws/{device}", ws_handler)
    app.on_shutdown.append(on_shutdown)
    web.run_app(app, host="0.0.0.0", port=PORT, print=None)


if __name__ == "__main__":
    main()
