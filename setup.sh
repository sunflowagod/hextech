#!/usr/bin/env bash
# ============================================================
#  setup.sh — clawtank studio, one-shot installer
#
#  Creates clawtank-studio/ with:
#    - editor + live emulator preview (FastAPI + WebSocket)
#    - streaming build log (BUILD & INSTALL button)
#    - hello.sh that AUTO-SOURCES everything in scripts/
#      when invoked with no arguments, so edits made in the
#      web UI actually reach the APK.
#
#  Usage:
#    chmod +x setup.sh
#    ./setup.sh
#    cd clawtank-studio && ./start.sh
# ============================================================
set -e

ROOT="clawtank-studio"

if [ -e "$ROOT" ]; then
  echo "!! $ROOT already exists."
  echo "   remove it first:  rm -rf $ROOT"
  exit 1
fi

mkdir -p "$ROOT"/{scripts,templates}
cd "$ROOT"

# ------------------------------------------------------------
#  housekeeping
# ------------------------------------------------------------
cat > .gitignore <<'EOF'
venv/
__pycache__/
*.pyc
.env
.DS_Store
clawtank/
*.apk
*.zip
.gradle/
build/
EOF

cat > requirements.txt <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
jinja2==3.1.4
python-multipart==0.0.9
aiohttp==3.9.5
EOF

cat > Procfile <<'EOF'
web: uvicorn main:app --host 0.0.0.0 --port $PORT
EOF

cat > README.md <<'EOF'
# clawtank studio

Editor + live Android emulator preview + BUILD & INSTALL.

    ./start.sh
    open http://127.0.0.1:8000

Requires: adb on PATH, an emulator in `adb devices`, java 17+.
Run `./startemu.sh 2` first if you need emulators.

## How builds pick up your edits

`hello.sh` auto-sources every file under `scripts/` when called
with no arguments. Edit `MainActivity.kt`, `strings.xml`,
`colors.xml` in the web UI, hit BUILD & INSTALL — the server
runs `hello.sh` bare, which copies `scripts/*` into the Gradle
project before compiling.
EOF

# ------------------------------------------------------------
#  default editable sources (live in scripts/)
# ------------------------------------------------------------
cat > scripts/MainActivity.kt <<'EOF'
package com.clawtank.app

import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = FrameLayout(this).apply {
            setBackgroundColor(ContextCompat.getColor(this@MainActivity, R.color.black))
        }

        val title = getString(R.string.main_title)

        val rainbowColors = intArrayOf(
            ContextCompat.getColor(this, R.color.rainbow_red),
            ContextCompat.getColor(this, R.color.rainbow_orange),
            ContextCompat.getColor(this, R.color.rainbow_yellow),
            ContextCompat.getColor(this, R.color.rainbow_green),
            ContextCompat.getColor(this, R.color.rainbow_blue),
            ContextCompat.getColor(this, R.color.rainbow_indigo),
            ContextCompat.getColor(this, R.color.rainbow_violet)
        )

        val spannable = SpannableString(title)
        for (i in title.indices) {
            val color = rainbowColors[i % rainbowColors.size]
            spannable.setSpan(
                ForegroundColorSpan(color),
                i, i + 1,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
        }

        val textView = TextView(this).apply {
            text = spannable
            textSize = 48f
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(32, 32, 32, 32)
        }

        root.addView(textView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        ))

        setContentView(root)
    }
}
EOF

cat > scripts/strings.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">clawtank</string>
    <string name="main_title">clawtank</string>
</resources>
EOF

cat > scripts/colors.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="black">#FF000000</color>
    <color name="white">#FFFFFFFF</color>
    <color name="rainbow_red">#FFFF0000</color>
    <color name="rainbow_orange">#FFFF7F00</color>
    <color name="rainbow_yellow">#FFFFFF00</color>
    <color name="rainbow_green">#FF00FF00</color>
    <color name="rainbow_blue">#FF0000FF</color>
    <color name="rainbow_indigo">#FF4B0082</color>
    <color name="rainbow_violet">#FF8B00FF</color>
</resources>
EOF

# ------------------------------------------------------------
#  hello.sh — build + install. Auto-sources scripts/* when no
#  file arguments are given, so web-UI edits reach the APK.
# ------------------------------------------------------------
cat > hello.sh <<'BASH'
#!/usr/bin/env bash
# ============================================================
#  hello.sh — build + install clawtank onto a chosen emulator
#
#     ./hello.sh
#         Auto-sources every file in scripts/ (MainActivity.kt,
#         strings.xml, colors.xml, …) and builds.
#
#     ./hello.sh 2
#         Same, but install onto emulator #2.
#
#     ./hello.sh scripts/MainActivity.kt
#         Use only the named file(s) instead of auto-sourcing.
#
#     ./hello.sh --fresh 2 scripts/MainActivity.kt
#         Wipe the Gradle project first (full re-scaffold).
# ============================================================
set -e

PROJECT_DIR="clawtank"
PACKAGE="com.clawtank.app"
ACTIVITY="MainActivity"
GRADLE_VERSION="8.9"
ANDROID_API="34"
BUILD_TOOLS="34.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- parse args ----------
FRESH=0
EMU_INDEX=1
SOURCE_FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1; shift ;;
    [0-9]*)  EMU_INDEX="$1"; shift ;;
    *)       SOURCE_FILES+=("$1"); shift ;;
  esac
done

# ---------- auto-source scripts/ when no files were passed ----------
if [ ${#SOURCE_FILES[@]} -eq 0 ]; then
  SCRIPT_SRC_DIR="$SCRIPT_DIR/scripts"
  if [ -d "$SCRIPT_SRC_DIR" ]; then
    while IFS= read -r -d '' f; do
      SOURCE_FILES+=("$f")
    done < <(find "$SCRIPT_SRC_DIR" -type f -print0 | sort -z)
    if [ ${#SOURCE_FILES[@]} -gt 0 ]; then
      echo ""
      echo "  Auto-sourcing from scripts/:"
      for f in "${SOURCE_FILES[@]}"; do echo "    $(basename "$f")"; done
    fi
  fi
fi

echo ""
echo "  Project   : $PROJECT_DIR"
echo "  Emulator  : #$EMU_INDEX"
if [ ${#SOURCE_FILES[@]} -gt 0 ]; then
  echo "  Sources   :"
  for f in "${SOURCE_FILES[@]}"; do echo "             $f"; done
else
  echo "  Sources   : (built-in defaults)"
fi

echo ""
echo "  Checking / installing Java..."
if ! command -v java >/dev/null 2>&1; then
  sudo apt-get update -qq
  if apt-cache show openjdk-17-jdk >/dev/null 2>&1; then
    sudo apt-get install -y -qq openjdk-17-jdk
  elif apt-cache show openjdk-21-jdk >/dev/null 2>&1; then
    sudo apt-get install -y -qq openjdk-21-jdk
  else
    sudo apt-get install -y -qq default-jdk
  fi
fi

if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_BIN=$(readlink -f "$(command -v java)")
  JAVA_HOME=$(dirname "$(dirname "$JAVA_BIN")")
  export JAVA_HOME
fi
echo "  JAVA_HOME = $JAVA_HOME"
java -version 2>&1 | head -3
JAVA_MAJOR=$(java -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')
echo "  Java major: $JAVA_MAJOR"

# ---------- Android SDK ----------
SDK_ROOT="${ANDROID_HOME:-$HOME/Android/Sdk}"
CMDLINE_TOOLS="$SDK_ROOT/cmdline-tools/latest"

if [ ! -d "$CMDLINE_TOOLS/bin" ]; then
  echo ""
  echo "  Downloading Android command-line tools..."
  mkdir -p "$SDK_ROOT/cmdline-tools"
  TMP_ZIP=$(mktemp /tmp/cmdline-tools-XXXX.zip)
  curl -fL -o "$TMP_ZIP" \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  unzip -q -o "$TMP_ZIP" -d "$SDK_ROOT/cmdline-tools"
  if [ -d "$SDK_ROOT/cmdline-tools/cmdline-tools" ]; then
    mv "$SDK_ROOT/cmdline-tools/cmdline-tools" "$CMDLINE_TOOLS"
  fi
  rm -f "$TMP_ZIP"
fi

export ANDROID_HOME="$SDK_ROOT"
export PATH="$CMDLINE_TOOLS/bin:$SDK_ROOT/platform-tools:$PATH"
echo "  ANDROID_HOME = $ANDROID_HOME"

echo "  Installing platform + build-tools..."
yes | sdkmanager --sdk_root="$SDK_ROOT" \
  "platforms;android-${ANDROID_API}" \
  "build-tools;${BUILD_TOOLS}" \
  "platform-tools" >/dev/null || true

# ---------- Gradle ----------
GRADLE_CACHE_DIR="$HOME/.local/share/hello-sh-gradle"
GRADLE_HOME="$GRADLE_CACHE_DIR/gradle-${GRADLE_VERSION}"
GRADLE_BIN="$GRADLE_HOME/bin/gradle"

if [ ! -x "$GRADLE_BIN" ]; then
  echo ""
  echo "  Fetching Gradle ${GRADLE_VERSION}..."
  mkdir -p "$GRADLE_CACHE_DIR"
  ZIP_PATH="$GRADLE_CACHE_DIR/gradle-${GRADLE_VERSION}-bin.zip"
  curl -fL -o "$ZIP_PATH" \
    "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
  unzip -q -o "$ZIP_PATH" -d "$GRADLE_CACHE_DIR"
fi
echo "  Gradle: $GRADLE_BIN"

# ---------- scaffold or reuse ----------
if [ -d "$PROJECT_DIR" ] && [ "$FRESH" = "0" ]; then
  echo "  Reusing existing $PROJECT_DIR"
  cd "$PROJECT_DIR"
else
  echo "  Creating $PROJECT_DIR..."
  rm -rf "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"/app/src/main/{java/com/clawtank/app,res/layout,res/values}
  cd "$PROJECT_DIR"

  cat > settings.gradle.kts << 'EOF'
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "clawtank"
include(":app")
EOF

  cat > build.gradle.kts << 'EOF'
plugins {
    id("com.android.application") version "8.7.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}
EOF

  cat > app/build.gradle.kts << EOF
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.clawtank.app"
    compileSdk = ${ANDROID_API}

    defaultConfig {
        applicationId = "com.clawtank.app"
        minSdk = 24
        targetSdk = ${ANDROID_API}
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_${JAVA_MAJOR}
        targetCompatibility = JavaVersion.VERSION_${JAVA_MAJOR}
    }
    kotlinOptions {
        jvmTarget = "${JAVA_MAJOR}"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
EOF

  cat > app/src/main/AndroidManifest.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:allowBackup="true"
        android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.AppCompat.Light.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

  cat > app/src/main/res/values/strings.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">clawtank</string>
    <string name="main_title">clawtank</string>
</resources>
EOF

  cat > app/src/main/res/values/colors.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="black">#FF000000</color>
    <color name="white">#FFFFFFFF</color>
    <color name="rainbow_red">#FFFF0000</color>
    <color name="rainbow_orange">#FFFF7F00</color>
    <color name="rainbow_yellow">#FFFFFF00</color>
    <color name="rainbow_green">#FF00FF00</color>
    <color name="rainbow_blue">#FF0000FF</color>
    <color name="rainbow_indigo">#FF4B0082</color>
    <color name="rainbow_violet">#FF8B00FF</color>
</resources>
EOF

  cat > gradle.properties << 'EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
kotlin.code.style=official
EOF
fi

# ---------- copy user sources ----------
mkdir -p app/src/main/java/com/clawtank/app
mkdir -p app/src/main/res/values

for SRC in "${SOURCE_FILES[@]}"; do
  if [ -f "$SRC" ]; then
    FULL="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
  elif [ -f "$SCRIPT_DIR/$SRC" ]; then
    FULL="$SCRIPT_DIR/$SRC"
  else
    echo "  WARNING: file not found: $SRC (skipping)"
    continue
  fi
  BASE=$(basename "$FULL")
  case "$BASE" in
    *.kt)
      echo "  → Kotlin   : $BASE"
      {
        echo "package com.clawtank.app"
        echo ""
        grep -v '^[[:space:]]*package[[:space:]]' "$FULL" || true
      } > app/src/main/java/com/clawtank/app/"$BASE"
      # keep MainActivity.kt as the launcher target
      if [ "$BASE" = "MainActivity.kt" ]; then
        :
      fi
      ;;
    strings.xml) echo "  → strings  : $BASE"; cp "$FULL" app/src/main/res/values/strings.xml ;;
    colors.xml)  echo "  → colors   : $BASE"; cp "$FULL" app/src/main/res/values/colors.xml  ;;
    *)           echo "  WARNING: ignoring $BASE" ;;
  esac
done

# fallback to rainbow default if MainActivity is missing
if [ ! -f app/src/main/java/com/clawtank/app/MainActivity.kt ]; then
  echo "  → using built-in rainbow MainActivity"
  cat > app/src/main/java/com/clawtank/app/MainActivity.kt << 'EOF'
package com.clawtank.app

import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this).apply {
            setBackgroundColor(ContextCompat.getColor(this@MainActivity, R.color.black))
        }
        val title = getString(R.string.main_title)
        val rainbowColors = intArrayOf(
            ContextCompat.getColor(this, R.color.rainbow_red),
            ContextCompat.getColor(this, R.color.rainbow_orange),
            ContextCompat.getColor(this, R.color.rainbow_yellow),
            ContextCompat.getColor(this, R.color.rainbow_green),
            ContextCompat.getColor(this, R.color.rainbow_blue),
            ContextCompat.getColor(this, R.color.rainbow_indigo),
            ContextCompat.getColor(this, R.color.rainbow_violet)
        )
        val spannable = SpannableString(title)
        for (i in title.indices) {
            spannable.setSpan(
                ForegroundColorSpan(rainbowColors[i % rainbowColors.size]),
                i, i + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
        }
        val tv = TextView(this).apply {
            text = spannable
            textSize = 48f
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(32, 32, 32, 32)
        }
        root.addView(tv, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        ))
        setContentView(root)
    }
}
EOF
fi

echo "sdk.dir=$SDK_ROOT" > local.properties

# ---------- regenerate wrapper ----------
echo ""
echo "  Generating Gradle wrapper..."
rm -rf gradle/wrapper
mkdir -p gradle/wrapper
"$GRADLE_BIN" wrapper --gradle-version "$GRADLE_VERSION" --quiet
chmod +x gradlew

# ---------- build ----------
echo ""
echo "  Building debug APK (2-4 min on first run)..."
echo "  Streaming gradle output below."
echo ""

./gradlew assembleDebug --no-daemon --console=plain

APK="app/build/outputs/apk/debug/app-debug.apk"
if [ ! -f "$APK" ]; then
  echo "ERROR: APK was not produced"
  exit 1
fi
echo "  APK ready: $APK"

# ---------- pick emulator ----------
echo ""
echo "  Looking for emulator #$EMU_INDEX..."
mapfile -t DEVICES < <(adb devices | awk '/device$/{print $1}')

if [ ${#DEVICES[@]} -eq 0 ]; then
  echo "ERROR: no running emulators. Start with: ./startemu.sh 2"
  exit 1
fi
if [ "$EMU_INDEX" -lt 1 ] || [ "$EMU_INDEX" -gt ${#DEVICES[@]} ]; then
  echo "ERROR: emulator index $EMU_INDEX out of range."
  for i in "${!DEVICES[@]}"; do
    echo "  $((i+1))) ${DEVICES[$i]}"
  done
  exit 1
fi

DEVICE="${DEVICES[$((EMU_INDEX-1))]}"
echo "  Using device: $DEVICE"
echo "  Installing..."
adb -s "$DEVICE" install -r "$APK"
echo "  Launching..."
adb -s "$DEVICE" shell am start -n "${PACKAGE}/.${ACTIVITY}"
echo ""
echo "  Done!"
echo ""
BASH
chmod +x hello.sh

# ------------------------------------------------------------
#  start.sh
# ------------------------------------------------------------
cat > start.sh <<'BASH'
#!/usr/bin/env bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
if [ ! -d venv ]; then
  python3 -m venv venv
fi
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
export HOST PORT
export MAX_SIZE="${MAX_SIZE:-720}"
export MAX_FPS="${MAX_FPS:-30}"
export BIT_RATE="${BIT_RATE:-4000000}"

if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "!! port $PORT already in use"
  echo "   lsof -ti:$PORT | xargs kill -9"
  exit 1
fi

echo ""
echo "  clawtank studio"
echo "  http://$HOST:$PORT"
echo "  stream: size=$MAX_SIZE fps=$MAX_FPS bitrate=$BIT_RATE"
echo ""
exec uvicorn main:app --host "$HOST" --port "$PORT" --reload
BASH
chmod +x start.sh

# ------------------------------------------------------------
#  main.py — FastAPI server. Uses the /ws/build streaming
#  build endpoint that calls hello.sh with NO arguments, so
#  hello.sh auto-sources everything under scripts/.
# ------------------------------------------------------------
cat > main.py <<'PYEOF'
#!/usr/bin/env python3
"""clawtank studio — editor + live emulator preview + streaming build."""
import os, json, random, asyncio, struct
from pathlib import Path
from fastapi import FastAPI, Request, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

HERE          = Path(__file__).resolve().parent
SCRIPTS_DIR   = HERE / "scripts"
TEMPLATES_DIR = HERE / "templates"
JAR_PATH      = Path("/tmp/scrcpy-server.jar")
SERVER_VER    = os.getenv("SERVER_VER", "3.1")
JAR_URL       = f"https://github.com/Genymobile/scrcpy/releases/download/v{SERVER_VER}/scrcpy-server-v{SERVER_VER}"

MAX_SIZE  = os.getenv("MAX_SIZE", "720")
MAX_FPS   = os.getenv("MAX_FPS", "30")
BIT_RATE  = os.getenv("BIT_RATE", "4000000")
ADB       = "adb"
DEBUG     = os.getenv("DEBUG", "") == "1"

SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
app = FastAPI(title="clawtank studio")
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))

# ---------------- control encoding ----------------
def encode_touch(x, y, w, h, action):
    p = 0 if action == 1 else 0xFFFF
    b = bytearray(32)
    b[0] = 2; b[1] = action
    struct.pack_into(">Q", b, 2, 0)
    struct.pack_into(">i", b, 10, int(x))
    struct.pack_into(">i", b, 14, int(y))
    struct.pack_into(">H", b, 18, int(w))
    struct.pack_into(">H", b, 20, int(h))
    struct.pack_into(">H", b, 22, p)
    struct.pack_into(">I", b, 24, 1)
    struct.pack_into(">I", b, 28, 0 if action == 1 else 1)
    return bytes(b)

def encode_key(code, action):
    b = bytearray(14); b[0] = 0; b[1] = action
    struct.pack_into(">i", b, 2, int(code)); return bytes(b)

def encode_text(t):
    p = t.encode("utf-8")
    b = bytearray(5 + len(p)); b[0] = 1
    struct.pack_into(">I", b, 1, len(p)); b[5:] = p
    return bytes(b)

def find_sps(a):
    i, n = 0, len(a)
    while i < n - 3:
        if a[i:i+4] == b"\x00\x00\x00\x01": off = i + 4
        elif a[i:i+3] == b"\x00\x00\x01":   off = i + 3
        else: i += 1; continue
        if off >= n: break
        if (a[off] & 0x1F) == 7 and off + 4 <= n:
            return a[off+1], a[off+2], a[off+3]
        i = off
    return None

async def list_devices():
    p = await asyncio.create_subprocess_exec(
        ADB, "devices", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, _ = await p.communicate()
    serials = []
    for line in out.decode("utf-8", "ignore").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])
    emus = [s for s in serials if s.startswith("emulator-")]
    rest = [s for s in serials if s not in emus]
    return emus + rest

# ---------------- scrcpy session ----------------
class ScrcpySession:
    def __init__(self, device_id):
        self.device_id    = device_id
        self.scid         = random.randint(1, 0x7FFFFFFF)
        self.forward_port = random.randint(27183, 27399)
        self.proc = self.video_rd = self.video_wr = None
        self.control_wr   = None
        self.device_name  = device_id
        self.width        = 0
        self.height       = 0
        self.codec_string = "avc1.42E01E"
        self._clock       = asyncio.Lock()
        self._subscribers = set()
        self._reader_task = None
        self._running     = False
        self._cached_config   = None
        self._cached_keyframe = None

    async def _adb(self, *args, timeout=30):
        p = await asyncio.create_subprocess_exec(
            ADB, "-s", self.device_id, *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            out, err = await asyncio.wait_for(p.communicate(), timeout=timeout)
            return p.returncode, out.decode("utf-8", "ignore"), err.decode("utf-8", "ignore")
        except asyncio.TimeoutError:
            p.kill(); return -1, "", "timeout"

    async def _setup(self):
        rc, out, _ = await self._adb("shell", "echo", "ok", timeout=8)
        if "ok" not in out: raise RuntimeError(f"{self.device_id} not responding")
        await self._adb("shell", "input", "keyevent", "KEYCODE_WAKEUP", timeout=5)
        await self._adb("shell", "wm", "dismiss-keyguard", timeout=5)
        await self._adb("shell", "pkill", "-f", "com.genymobile.scrcpy.Server", timeout=5)
        await asyncio.sleep(0.5)

        if not (JAR_PATH.exists() and JAR_PATH.stat().st_size > 10000):
            print("  downloading scrcpy-server.jar")
            p = await asyncio.create_subprocess_exec(
                "curl", "-L", "-s", "-o", str(JAR_PATH), JAR_URL,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            await p.wait()

        rc, _, err = await self._adb("push", str(JAR_PATH), "/data/local/tmp/scrcpy-server.jar")
        if rc != 0: raise RuntimeError(f"push failed: {err.strip()}")

        abstract = f"scrcpy_{self.scid:08x}"
        await self._adb("forward", "--remove", f"tcp:{self.forward_port}", timeout=3)
        rc, _, err = await self._adb("forward", f"tcp:{self.forward_port}", f"localabstract:{abstract}")
        if rc != 0: raise RuntimeError(f"forward failed: {err.strip()}")

        args = [SERVER_VER, f"scid={self.scid:08x}", "log_level=info",
                f"max_size={MAX_SIZE}", f"max_fps={MAX_FPS}",
                f"video_bit_rate={BIT_RATE}", "tunnel_forward=true",
                "audio=false", "control=true", "cleanup=true"]
        cmd = ("CLASSPATH=/data/local/tmp/scrcpy-server.jar "
               "app_process / com.genymobile.scrcpy.Server " + " ".join(args))
        self.proc = await asyncio.create_subprocess_exec(
            ADB, "-s", self.device_id, "shell", cmd,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        asyncio.create_task(self._pump(self.proc.stderr))
        await asyncio.sleep(2.5)

    async def _pump(self, stream):
        try:
            while True:
                line = await stream.readline()
                if not line: break
                if DEBUG: print("  [srv]", line.decode("utf-8", "ignore").rstrip())
        except Exception: pass

    async def _connect(self):
        for _ in range(50):
            try:
                self.video_rd, self.video_wr = await asyncio.open_connection("127.0.0.1", self.forward_port)
                break
            except (ConnectionRefusedError, OSError): await asyncio.sleep(0.3)
        else: raise RuntimeError("video connect failed")

        for _ in range(50):
            try:
                _, self.control_wr = await asyncio.open_connection("127.0.0.1", self.forward_port)
                break
            except (ConnectionRefusedError, OSError): await asyncio.sleep(0.3)
        else: raise RuntimeError("control connect failed")

    @staticmethod
    async def _read_exact(r, n, timeout=None):
        async def _do():
            buf = bytearray()
            while len(buf) < n:
                chunk = await r.read(n - len(buf))
                if not chunk: raise EOFError(f"EOF {len(buf)}/{n}")
                buf.extend(chunk)
            return bytes(buf)
        if timeout is None: return await _do()
        return await asyncio.wait_for(_do(), timeout=timeout)

    async def _read_metadata(self):
        await self._read_exact(self.video_rd, 1, timeout=25)
        raw = await self._read_exact(self.video_rd, 64, timeout=25)
        self.device_name = raw.rstrip(b"\x00").decode("utf-8", "ignore") or self.device_id
        meta = await self._read_exact(self.video_rd, 12, timeout=10)
        codec_id, w, h = struct.unpack(">III", meta)
        if w < 0: w = -w
        if h < 0: h = -h
        self.width, self.height = w, h
        print(f"  scrcpy {self.device_id}: {self.device_name!r} {w}x{h}")

    async def _next_packet(self):
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
            if not self.control_wr: return
            try:
                self.control_wr.write(data)
                await self.control_wr.drain()
            except Exception: pass

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

    def unsubscribe(self, q): self._subscribers.discard(q)

    async def _reader_loop(self):
        while self._running:
            try:
                pkt = await self._next_packet()
            except asyncio.CancelledError: break
            except Exception as e:
                print(f"  reader: {type(e).__name__}: {e!r}"); break
            if pkt.get("skip"): continue
            if pkt["config"]:
                sps = find_sps(pkt["payload"])
                if sps:
                    p, c, l = sps
                    self.codec_string = f"avc1.{p:02X}{c:02X}{l:02X}"
            flags = 0
            if pkt["key"]: flags |= 0x01
            if pkt["config"]: flags |= 0x02
            data = bytes([flags]) + pkt["payload"]
            if pkt["config"]: self._cached_config = data
            elif pkt["key"]: self._cached_keyframe = data
            for q in list(self._subscribers):
                try: q.put_nowait(data)
                except asyncio.QueueFull:
                    try: q.get_nowait()
                    except Exception: pass
                    try: q.put_nowait(data)
                    except Exception: pass

    async def start(self):
        await self._setup()
        await self._connect()
        await self._read_metadata()
        self._running = True
        self._reader_task = asyncio.create_task(self._reader_loop())
        print(f"  scrcpy {self.device_id}: ready")

    async def stop(self):
        self._running = False
        if self._reader_task:
            self._reader_task.cancel()
            try: await self._reader_task
            except Exception: pass
        for w in (self.video_wr, self.control_wr):
            if w:
                try: w.close()
                except Exception: pass
        if self.proc:
            try: self.proc.kill()
            except Exception: pass
        try: await self._adb("forward", "--remove", f"tcp:{self.forward_port}")
        except Exception: pass


_session = None
_session_lock = asyncio.Lock()

async def get_session():
    global _session
    async with _session_lock:
        if _session and _session._running:
            return _session
        if _session:
            try: await _session.stop()
            except Exception: pass
            _session = None
        devices = await list_devices()
        if not devices: raise RuntimeError("no adb device — start an emulator")
        _session = ScrcpySession(devices[0])
        await _session.start()
        return _session

# ---------------- routes ----------------
@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/api/files")
async def files():
    return [{"name": str(p.relative_to(SCRIPTS_DIR)), "size": p.stat().st_size}
            for p in sorted(SCRIPTS_DIR.rglob("*")) if p.is_file()]

@app.get("/api/files/{name:path}")
async def read_file(name: str):
    p = (SCRIPTS_DIR / name).resolve()
    if not str(p).startswith(str(SCRIPTS_DIR.resolve())) or not p.is_file():
        raise HTTPException(404, "not found")
    return {"name": name, "content": p.read_text(errors="replace")}

@app.put("/api/files/{name:path}")
async def write_file(name: str, body: dict):
    p = (SCRIPTS_DIR / name).resolve()
    if not str(p).startswith(str(SCRIPTS_DIR.resolve())):
        raise HTTPException(400, "invalid path")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body.get("content", ""))
    return {"ok": True}

@app.get("/api/devices")
async def devices():
    return {"devices": await list_devices()}

# ---------------- STREAMING BUILD ----------------
@app.websocket("/ws/build")
async def ws_build(ws: WebSocket):
    """
    Streams hello.sh output line by line.
    hello.sh is called with NO arguments, which makes it
    auto-source every file under scripts/. That's how edits
    made in the web UI reach the APK.
    """
    await ws.accept()

    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["TERM"] = "dumb"

    try:
        proc = await asyncio.create_subprocess_exec(
            "stdbuf", "-oL", "-eL",
            "bash", str(HERE / "hello.sh"),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(HERE),
            env=env,
        )
    except FileNotFoundError:
        proc = await asyncio.create_subprocess_exec(
            "bash", str(HERE / "hello.sh"),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(HERE),
            env=env,
        )

    async def heartbeat():
        try:
            n = 0
            while True:
                await asyncio.sleep(10)
                n += 10
                try:
                    await ws.send_text(f"\n[clawtank] still running… ({n}s)\n")
                except Exception:
                    return
        except asyncio.CancelledError:
            return

    hb = asyncio.create_task(heartbeat())

    try:
        buffer = b""
        while True:
            chunk = await proc.stdout.read(512)
            if not chunk:
                break
            buffer += chunk
            buffer = buffer.replace(b"\r", b"\n")
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                text = line.decode("utf-8", "replace")
                if text.strip() == "":
                    continue
                try:
                    await ws.send_text(text + "\n")
                except Exception:
                    proc.kill()
                    return
        if buffer.strip():
            try:
                await ws.send_text(buffer.decode("utf-8", "replace") + "\n")
            except Exception:
                pass

        try:
            code = await asyncio.wait_for(proc.wait(), timeout=60)
        except asyncio.TimeoutError:
            proc.kill()
            code = -1

        try:
            await ws.send_text(json.dumps({"done": True, "code": code}) + "\n")
        except Exception:
            pass
    except Exception as e:
        try:
            await ws.send_text(f"[clawtank] error: {e}\n")
            await ws.send_text(json.dumps({"done": True, "code": -1}) + "\n")
        except Exception:
            pass
    finally:
        hb.cancel()
        try:
            await ws.close()
        except Exception:
            pass

# ---------------- EMULATOR STREAM ----------------
@app.websocket("/ws/stream")
async def ws_stream(ws: WebSocket):
    await ws.accept()
    try:
        session = await get_session()
    except Exception as e:
        await ws.send_json({"type": "error", "message": str(e)})
        await ws.close(); return

    await ws.send_json({
        "type": "meta",
        "device": session.device_name,
        "width": session.width,
        "height": session.height,
        "codec": session.codec_string,
    })

    try:
        while True:
            msg = await asyncio.wait_for(ws.receive_text(), timeout=20)
            if '"ready"' in msg: break
    except Exception:
        await ws.close(); return

    q = session.subscribe()

    async def pump():
        try:
            while True:
                data = await q.get()
                await ws.send_bytes(data)
        except Exception:
            pass

    pump_task = asyncio.create_task(pump())

    try:
        while True:
            raw = await ws.receive_text()
            try: d = json.loads(raw)
            except Exception: continue
            t = d.get("type")
            if t == "tap":
                await session.send_control(encode_touch(d["x"], d["y"], session.width, session.height, 0))
                await session.send_control(encode_touch(d["x"], d["y"], session.width, session.height, 1))
            elif t == "swipe":
                x1, y1, x2, y2 = d["x1"], d["y1"], d["x2"], d["y2"]
                await session.send_control(encode_touch(x1, y1, session.width, session.height, 0))
                for i in range(1, 8):
                    await session.send_control(encode_touch(
                        x1 + (x2-x1)*i/8, y1 + (y2-y1)*i/8,
                        session.width, session.height, 2))
                await session.send_control(encode_touch(x2, y2, session.width, session.height, 1))
            elif t == "key":
                await session.send_control(encode_key(int(d.get("code", 4)), 0))
                await session.send_control(encode_key(int(d.get("code", 4)), 1))
            elif t == "text":
                await session.send_control(encode_text(str(d.get("text", ""))))
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        pump_task.cancel()
        session.unsubscribe(q)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=os.getenv("HOST", "127.0.0.1"), port=int(os.getenv("PORT", "8000")))
PYEOF

# ------------------------------------------------------------
#  templates/index.html — editor + preview + streaming build
# ------------------------------------------------------------
cat > templates/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>clawtank — studio</title>
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet" />
<style>
  :root {
    --bg:#0b0d10; --surface:#12151a; --surface2:#1a1e26; --border:#2a3140;
    --text:#e8eaed; --muted:#8b93a7; --accent:#ff6b00; --green:#3dd68c;
    --font:"Inter",system-ui,sans-serif;
    --mono:"JetBrains Mono",ui-monospace,monospace;
    --tok-keyword:#ff7a3d; --tok-type:#5b9dff; --tok-string:#3dd68c;
    --tok-comment:#5f6677; --tok-number:#ffb86b; --tok-func:#ffd479;
    --tok-annotation:#c586c0; --tok-tag:#5b9dff; --tok-attr:#56d4dd;
    --tok-punct:#8b93a7; --tok-meta:#c586c0;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%}
  body{font-family:var(--font);background:var(--bg);color:var(--text);
       display:grid;grid-template-rows:auto 1fr;overflow:hidden}
  header{display:flex;align-items:center;justify-content:space-between;
    padding:12px 20px;border-bottom:1px solid var(--border);background:var(--surface)}
  .logo{display:flex;align-items:center;gap:10px;font-weight:700;font-size:1.05rem}
  .logo span{color:var(--accent)}
  .badge{font-size:.62rem;font-weight:600;background:var(--accent);color:#000;
    padding:2px 7px;border-radius:999px;text-transform:uppercase;letter-spacing:.04em}
  .hd-actions{display:flex;gap:8px;align-items:center}
  .hd-actions button{font-family:var(--font);font-size:.8rem;font-weight:560;
    padding:7px 14px;border-radius:7px;cursor:pointer;
    background:var(--surface2);border:1px solid var(--border);color:var(--text);
    transition:background .15s}
  .hd-actions button:hover{background:#222833}
  .hd-actions button.primary{background:var(--accent);border-color:var(--accent);color:#000}
  .hd-actions button.primary:hover{background:#ff8533}
  .shell{display:grid;grid-template-columns:220px 1fr 360px;min-height:0;overflow:hidden}
  @media(max-width:900px){ .shell{grid-template-columns:1fr} aside{display:none} }
  aside.files{background:var(--surface);border-right:1px solid var(--border);
    display:flex;flex-direction:column;overflow:hidden}
  .aside-head{padding:14px 14px 8px}
  .aside-head h2{font-size:.7rem;text-transform:uppercase;letter-spacing:.08em;
    color:var(--muted);font-weight:600}
  .file-list{list-style:none;overflow-y:auto;flex:1;padding:0 8px 14px}
  .file-item{display:flex;align-items:center;gap:8px;padding:8px 10px;
    border-radius:7px;cursor:pointer;font-size:.8rem;color:var(--muted);
    font-family:var(--mono);transition:background .12s}
  .file-item:hover{background:var(--surface2);color:var(--text)}
  .file-item.active{background:var(--surface2);color:var(--text);
    box-shadow:inset 3px 0 0 var(--accent)}
  .file-name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  main.editor{display:flex;flex-direction:column;min-width:0;
    border-right:1px solid var(--border)}
  .toolbar{display:flex;align-items:center;gap:12px;padding:8px 16px;
    border-bottom:1px solid var(--border);background:var(--surface)}
  .path{flex:1;font-family:var(--mono);font-size:.78rem;color:var(--muted)}
  .path strong{color:var(--text)}
  .toolbar button{font-family:var(--font);font-size:.75rem;padding:5px 11px;
    border-radius:6px;background:var(--surface2);color:var(--text);
    border:1px solid var(--border);cursor:pointer}
  .toolbar button:hover{background:#222833}
  .editor-wrap{flex:1;position:relative;min-height:0;overflow:hidden}
  #editor,.highlight{position:absolute;inset:0;margin:0;padding:18px 22px;border:0;
    font-family:var(--mono);font-size:.85rem;line-height:1.6;tab-size:4;
    white-space:pre;overflow:auto}
  #editor{background:transparent;color:transparent;caret-color:var(--text);
    resize:none;outline:none;z-index:2}
  #editor::selection{background:rgba(255,107,0,.35);color:transparent}
  .highlight{background:var(--bg);color:var(--text);z-index:1;pointer-events:none;overflow:hidden}
  .highlight code{font:inherit;white-space:inherit;display:block;min-height:100%}
  .tok-keyword{color:var(--tok-keyword);font-weight:600}
  .tok-type{color:var(--tok-type)} .tok-string{color:var(--tok-string)}
  .tok-comment{color:var(--tok-comment);font-style:italic}
  .tok-number{color:var(--tok-number)} .tok-func{color:var(--tok-func)}
  .tok-annotation{color:var(--tok-annotation)} .tok-tag{color:var(--tok-tag)}
  .tok-attr{color:var(--tok-attr)} .tok-punct{color:var(--tok-punct)}
  .tok-meta{color:var(--tok-meta)}
  aside.preview{background:var(--surface);display:flex;flex-direction:column;
    align-items:center;padding:16px 14px;gap:12px;overflow-y:auto}
  .preview-title{font-family:var(--mono);font-size:.72rem;color:var(--muted);
    text-transform:uppercase;letter-spacing:.08em}
  .phone{position:relative;width:300px;aspect-ratio:300/620;padding:5px;
    border-radius:44px;flex-shrink:0;
    background:linear-gradient(160deg,
      #f8f7f4 0%,#d6d2c8 14%,#b8b3a7 45%,#a09a8d 62%,#cfcabe 86%,#f0eee9 100%);
    box-shadow:0 0 0 2px #8a8377,0 0 0 4px #b8b3a7,0 20px 40px rgba(0,0,0,.5)}
  .bezel{position:relative;width:100%;height:100%;border-radius:40px;
    background:#08060a;padding:11px}
  .island{position:absolute;top:18px;left:50%;transform:translateX(-50%);
    width:76px;height:24px;background:#000;border-radius:999px;z-index:10}
  .island::before{content:"";position:absolute;top:50%;right:13px;
    transform:translateY(-50%);width:8px;height:8px;border-radius:50%;background:#04040a}
  .island::after{content:"";position:absolute;top:50%;left:13px;
    transform:translateY(-50%);width:26px;height:4px;background:#0a0a12;border-radius:2px}
  .screen{position:relative;width:100%;height:100%;overflow:hidden;
    border-radius:28px;background:#0b0805;display:flex;align-items:center;justify-content:center}
  .screen canvas{display:block;width:100%;height:100%;cursor:crosshair;touch-action:none}
  .home-bar{position:absolute;bottom:6px;left:50%;transform:translateX(-50%);
    width:76px;height:4px;border-radius:3px;background:rgba(255,234,203,.55);
    z-index:8;pointer-events:none}
  .pill{display:inline-flex;align-items:center;gap:.5rem;font-family:var(--mono);
    font-size:.7rem;padding:.35rem .6rem;border:1px solid var(--border);
    background:var(--surface2);color:var(--muted);border-radius:7px}
  .pill .dot{width:7px;height:7px;border-radius:50%;background:#b03a2e}
  .pill.on .dot{background:var(--green)}
  .pill.on{color:var(--green);border-color:rgba(61,214,140,.4)}
  .preview-actions{display:flex;gap:8px;flex-wrap:wrap;justify-content:center}
  .preview-actions button{font-family:var(--font);font-size:.75rem;font-weight:600;
    padding:8px 14px;border-radius:7px;cursor:pointer;background:var(--surface2);
    color:var(--text);border:1px solid var(--border);transition:background .15s}
  .preview-actions button:hover{background:#222833}
  .preview-actions button.accent{background:var(--accent);border-color:var(--accent);color:#000}
  .preview-actions button.accent:hover{background:#ff8533}
  .preview-actions button:disabled{opacity:.5;cursor:not-allowed}
  .log{width:100%;height:240px;overflow:auto;background:#05070a;
    border:1px solid var(--border);border-radius:8px;padding:10px;
    font-family:var(--mono);font-size:.7rem;line-height:1.5;color:#c8d0dd;
    white-space:pre-wrap;word-break:break-all}
  .log:empty{display:none}
  ::-webkit-scrollbar{width:8px;height:8px}
  ::-webkit-scrollbar-thumb{background:#2a3140;border-radius:4px}
  ::-webkit-scrollbar-thumb:hover{background:#3a4458}
</style>
</head>
<body>
<header>
  <div class="logo">claw<span>tank</span><span class="badge">studio</span></div>
  <div class="hd-actions">
    <button id="btnNew">+ New file</button>
    <button class="primary" id="btnSave" disabled>Save</button>
  </div>
</header>
<div class="shell">
  <aside class="files">
    <div class="aside-head"><h2>scripts/</h2></div>
    <ul class="file-list" id="fileList"></ul>
  </aside>
  <main class="editor">
    <div class="toolbar">
      <div class="path" id="currentPath">Select a file…</div>
      <button id="btnCopy" disabled>Copy</button>
    </div>
    <div class="editor-wrap">
      <pre class="highlight" aria-hidden="true"><code id="hlCode"></code></pre>
      <textarea id="editor" wrap="off" spellcheck="false" style="display:none"></textarea>
    </div>
  </main>
  <aside class="preview">
    <div class="preview-title">live emulator</div>
    <div class="phone">
      <div class="bezel">
        <div class="island"></div>
        <div class="screen"><canvas id="cv" width="720" height="1560"></canvas></div>
      </div>
      <span class="home-bar"></span>
    </div>
    <span class="pill" id="pill"><span class="dot"></span><span id="pillTxt">connecting</span></span>
    <div class="preview-actions">
      <button id="btnHome">HOME</button>
      <button id="btnBack">BACK</button>
      <button id="btnBuild" class="accent">BUILD &amp; INSTALL</button>
    </div>
    <pre class="log" id="log"></pre>
  </aside>
</div>
<script>
function esc(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}
const KT_KW = ["package","import","class","interface","object","fun","val","var",
  "override","open","abstract","final","private","public","protected","internal",
  "return","if","else","when","for","while","do","break","continue","this","super",
  "null","true","false","is","as","in","out","by","where","try","catch","finally",
  "throw","companion","init","constructor","get","set","lateinit","suspend",
  "inline","data","sealed","enum","annotation","const","operator","infix"].join("|");
const RULES = {
  kt: [
    {cls:"comment", re:/\/\/[^\n]*/},
    {cls:"comment", re:/\/\*[\s\S]*?\*\//},
    {cls:"string",  re:/"(?:[^"\\\n]|\\.)*"/},
    {cls:"string",  re:/'(?:[^'\\\n]|\\.)*'/},
    {cls:"annotation", re:/@[A-Za-z_][A-Za-z0-9_]*/},
    {cls:"number",  re:/\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?[fFlLdD]?)\b/},
    {cls:"keyword", re:new RegExp("\\b(?:"+KT_KW+")\\b")},
    {cls:"type",    re:/\b[A-Z][A-Za-z0-9_]*\b/},
    {cls:"func",    re:/\b[a-z_][A-Za-z0-9_]*(?=\s*\()/}
  ],
  xml: [
    {cls:"comment", re:/<!--[\s\S]*?-->/},
    {cls:"meta",    re:/<\?[\s\S]*?\?>/},
    {cls:"string",  re:/"[^"\n]*"|'[^'\n]*'/},
    {cls:"attr",    re:/[A-Za-z_][A-Za-z0-9_:.-]*(?=\s*=)/},
    {cls:"tag",     re:/[A-Za-z_][A-Za-z0-9_:.-]*/},
    {cls:"punct",   re:/<\/?|\/?>|=|\//}
  ],
  plain: []
};
function highlight(code, lang){
  const rules = RULES[lang] || [];
  if(!rules.length) return esc(code);
  const src = rules.map(r => "("+r.re.source+")").join("|");
  const re = new RegExp(src, "g");
  let out = "", last = 0, m;
  while((m = re.exec(code)) !== null){
    if(m.index > last) out += esc(code.slice(last, m.index));
    for(let i = 1; i <= rules.length; i++){
      if(m[i] !== undefined){
        out += '<span class="tok-'+rules[i-1].cls+'">'+esc(m[i])+'</span>';
        break;
      }
    }
    last = m.index + m[0].length;
    if(m[0].length === 0) re.lastIndex++;
  }
  if(last < code.length) out += esc(code.slice(last));
  return out;
}
function pickLang(name){
  if(name.endsWith(".kt") || name.endsWith(".kts")) return "kt";
  if(name.endsWith(".xml")) return "xml";
  return "plain";
}
const editorEl = document.getElementById("editor");
const hlEl     = document.getElementById("hlCode");
const listEl   = document.getElementById("fileList");
const pathEl   = document.getElementById("currentPath");
let active = null, dirty = false;
function refreshHighlight(){
  if(!active) return;
  const html = highlight(editorEl.value, pickLang(active));
  hlEl.innerHTML = html + (editorEl.value.endsWith("\n") ? "\n" : "");
  document.querySelector(".highlight").scrollTop = editorEl.scrollTop;
  document.querySelector(".highlight").scrollLeft = editorEl.scrollLeft;
}
async function loadFiles(){
  const r = await fetch("/api/files");
  const files = await r.json();
  listEl.innerHTML = files.map(f =>
    '<li class="file-item" data-name="'+f.name+'">'+
    '<span class="file-name">'+f.name+'</span></li>').join("")
    || "<li style='padding:12px;color:var(--muted);font-size:.75rem'>no files</li>";
  listEl.querySelectorAll(".file-item").forEach(el =>
    el.onclick = () => openFile(el.dataset.name));
}
async function openFile(name){
  const r = await fetch("/api/files/"+encodeURIComponent(name));
  if(!r.ok) return;
  const d = await r.json();
  active = name;
  editorEl.style.display = "block";
  editorEl.value = d.content;
  pathEl.innerHTML = "<strong>"+name+"</strong>";
  document.getElementById("btnCopy").disabled = false;
  document.getElementById("btnSave").disabled = false;
  dirty = false;
  editorEl.scrollTop = 0; editorEl.scrollLeft = 0;
  refreshHighlight();
  listEl.querySelectorAll(".file-item").forEach(el =>
    el.classList.toggle("active", el.dataset.name === name));
}
editorEl.addEventListener("input", () => { refreshHighlight(); dirty = true; });
editorEl.addEventListener("scroll", () => {
  document.querySelector(".highlight").scrollTop  = editorEl.scrollTop;
  document.querySelector(".highlight").scrollLeft = editorEl.scrollLeft;
});
editorEl.addEventListener("keydown", e => {
  if(e.key === "Tab"){
    e.preventDefault();
    const s = editorEl.selectionStart, en = editorEl.selectionEnd;
    editorEl.value = editorEl.value.slice(0,s) + "    " + editorEl.value.slice(en);
    editorEl.selectionStart = editorEl.selectionEnd = s + 4;
    editorEl.dispatchEvent(new Event("input"));
  }
});
document.getElementById("btnSave").onclick = async () => {
  if(!active) return;
  await fetch("/api/files/"+encodeURIComponent(active), {
    method:"PUT", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({content: editorEl.value})});
  dirty = false;
  flash("saved");
};
document.getElementById("btnCopy").onclick = () => {
  navigator.clipboard.writeText(editorEl.value); flash("copied");
};
document.getElementById("btnNew").onclick = async () => {
  const name = prompt("New file name (e.g. Page3.kt or themes.xml):");
  if(!name) return;
  await fetch("/api/files/"+encodeURIComponent(name), {
    method:"PUT", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({content:""})});
  await loadFiles(); openFile(name);
};
function flash(msg){
  const p = document.getElementById("pillTxt");
  const old = p.textContent;
  p.textContent = msg;
  setTimeout(()=>p.textContent = old, 1200);
}

/* =========================================================
   Emulator preview
   ========================================================= */
const cv    = document.getElementById("cv");
const ctx   = cv.getContext("2d");
const pill  = document.getElementById("pill");
const pillT = document.getElementById("pillTxt");
let ws = null, decoder = null, configured = false;
let nativeW = 720, nativeH = 1560, ts = 0, lastCfg = null;
let pending = [], frames = 0, fpsT = performance.now();
function setPill(text, on){ pillT.textContent = text; pill.classList.toggle("on", !!on); }
function makeDecoder(){
  return new VideoDecoder({
    output(f){
      if(f.displayWidth !== nativeW || f.displayHeight !== nativeH){
        nativeW = f.displayWidth; nativeH = f.displayHeight;
        cv.width = nativeW; cv.height = nativeH;
      }
      ctx.drawImage(f, 0, 0, cv.width, cv.height);
      f.close();
      frames++;
      const now = performance.now();
      if(now - fpsT > 1000){ setPill(frames + " fps", true); frames = 0; fpsT = now; }
    },
    error(e){ console.error("decode", e); }
  });
}
async function configDecoder(preferred){
  const list = [preferred, "avc1.64001F","avc1.640028","avc1.4D401F",
                "avc1.4D401E","avc1.42E01F","avc1.42E01E","avc1.42C029"]
                .filter((v,i,a) => v && a.indexOf(v) === i);
  for(const codec of list){
    try{
      const s = await VideoDecoder.isConfigSupported({
        codec, codedWidth: nativeW, codedHeight: nativeH, optimizeForLatency: true});
      if(s.supported){
        decoder.configure({codec, codedWidth: nativeW, codedHeight: nativeH,
                           optimizeForLatency: true});
        configured = true;
        return codec;
      }
    }catch(e){}
  }
  return null;
}
function feed(buf){
  if(buf.length < 2) return;
  const flags = buf[0], isKey = (flags & 1) !== 0, isCfg = (flags & 2) !== 0;
  const payload = buf.subarray(1);
  if(isCfg){ lastCfg = payload; return; }
  let data = payload;
  if(isKey && lastCfg){
    data = new Uint8Array(lastCfg.length + payload.length);
    data.set(lastCfg, 0); data.set(payload, lastCfg.length);
  }
  ts += 33333;
  try{
    decoder.decode(new EncodedVideoChunk({
      type: isKey ? "key" : "delta", timestamp: ts, data}));
  }catch(e){}
}
function connectStream(){
  if(ws) try{ ws.close(); }catch(e){}
  const p = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(p + "//" + location.host + "/ws/stream");
  ws.binaryType = "arraybuffer";
  ws.onopen = () => {
    if(decoder) try{ decoder.close(); }catch(e){}
    decoder = makeDecoder(); configured = false; lastCfg = null; pending = [];
    setPill("waiting", false);
  };
  ws.onclose = () => { setPill("reconnecting", false); setTimeout(connectStream, 2500); };
  ws.onerror = () => setPill("error", false);
  ws.onmessage = async ev => {
    if(typeof ev.data === "string"){
      try{
        const m = JSON.parse(ev.data);
        if(m.type === "meta"){
          nativeW = m.width || nativeW; nativeH = m.height || nativeH;
          cv.width = nativeW; cv.height = nativeH;
          const used = await configDecoder(m.codec);
          if(used){
            setPill("live", true);
            ws.send(JSON.stringify({type:"ready"}));
            pending.forEach(feed); pending = [];
          } else setPill("no codec", false);
        } else if(m.type === "error"){
          setPill(m.message.slice(0,48), false);
        }
      }catch(e){}
      return;
    }
    const buf = new Uint8Array(ev.data);
    if(!configured){ pending.push(buf); if(pending.length > 512) pending.shift(); return; }
    feed(buf);
  };
}
function toDev(cx, cy){
  const r = cv.getBoundingClientRect();
  return {
    x: Math.max(0, Math.min(nativeW - 1, (cx - r.left) / r.width * nativeW)),
    y: Math.max(0, Math.min(nativeH - 1, (cy - r.top) / r.height * nativeH))};
}
function send(o){ if(ws && ws.readyState === 1) ws.send(JSON.stringify(o)); }
let drag = null;
cv.addEventListener("mousedown", e => { drag = toDev(e.clientX, e.clientY); });
cv.addEventListener("mouseup", e => {
  if(!drag) return;
  const p = toDev(e.clientX, e.clientY);
  if(Math.abs(p.x-drag.x) > 25 || Math.abs(p.y-drag.y) > 25)
    send({type:"swipe", x1:drag.x, y1:drag.y, x2:p.x, y2:p.y});
  else send({type:"tap", x:drag.x, y:drag.y});
  drag = null;
});
cv.addEventListener("touchstart", e => {
  e.preventDefault();
  const t = e.touches[0]; drag = toDev(t.clientX, t.clientY);
}, {passive:false});
cv.addEventListener("touchend", e => {
  e.preventDefault();
  if(!drag) return;
  const t = e.changedTouches[0]; const p = toDev(t.clientX, t.clientY);
  if(Math.abs(p.x-drag.x) > 25 || Math.abs(p.y-drag.y) > 25)
    send({type:"swipe", x1:drag.x, y1:drag.y, x2:p.x, y2:p.y});
  else send({type:"tap", x:drag.x, y:drag.y});
  drag = null;
}, {passive:false});
document.getElementById("btnHome").onclick = () => send({type:"key", code:3});
document.getElementById("btnBack").onclick = () => send({type:"key", code:4});

/* =========================================================
   Streaming build via /ws/build
   ========================================================= */
let buildWs = null;
document.getElementById("btnBuild").onclick = () => {
  const log = document.getElementById("log");
  const btn = document.getElementById("btnBuild");

  if(buildWs) try{ buildWs.close(); }catch(e){}

  log.textContent = "";
  btn.disabled = true;
  btn.textContent = "BUILDING…";

  if(active){
    fetch("/api/files/"+encodeURIComponent(active), {
      method:"PUT", headers:{"Content-Type":"application/json"},
      body: JSON.stringify({content: editorEl.value})
    }).catch(()=>{});
  }

  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  buildWs = new WebSocket(proto + "//" + location.host + "/ws/build");

  buildWs.onmessage = ev => {
    let text = ev.data;
    if(text.startsWith('{"done"')){
      try{
        const d = JSON.parse(text.trim());
        if(d.done){
          if(d.code === 0){
            btn.textContent = "BUILT ✓";
            log.textContent += "\n[clawtank] build succeeded ✓\n";
          } else {
            btn.textContent = "BUILD FAILED";
            log.textContent += `\n[clawtank] build failed (exit ${d.code})\n`;
          }
          log.scrollTop = log.scrollHeight;
          setTimeout(()=>{ btn.textContent = "BUILD & INSTALL"; btn.disabled = false; }, 3000);
          return;
        }
      }catch(e){}
    }
    log.textContent += text;
    log.scrollTop = log.scrollHeight;
  };

  buildWs.onclose = () => {
    if(btn.textContent === "BUILDING…"){
      btn.textContent = "BUILD & INSTALL";
      btn.disabled = false;
      log.textContent += "\n[clawtank] stream closed\n";
    }
    buildWs = null;
  };

  buildWs.onerror = () => {
    log.textContent += "\n[clawtank] stream error — check server logs\n";
    btn.textContent = "BUILD & INSTALL";
    btn.disabled = false;
    buildWs = null;
  };
};

loadFiles();
connectStream();
</script>
</body>
</html>
HTMLEOF

# ------------------------------------------------------------
#  done
# ------------------------------------------------------------
echo ""
echo "=================================================="
echo "  clawtank-studio created"
echo "=================================================="
echo ""
echo "  Next:"
echo "    cd $ROOT"
echo "    ./start.sh"
echo "    open http://127.0.0.1:8000"
echo ""
echo "  Make sure an emulator is running first:"
echo "    adb devices"
echo ""
echo "  Higher-res stream (optional):"
echo "    MAX_SIZE=1080 BIT_RATE=6000000 MAX_FPS=30 ./start.sh"
echo ""
echo "  How builds pick up your edits:"
echo "    BUILD & INSTALL runs hello.sh with NO arguments,"
echo "    which auto-sources everything under scripts/."
echo "    Edit MainActivity.kt / strings.xml / colors.xml in"
echo "    the web UI, hit BUILD & INSTALL, and the change"
echo "    will land in the APK."
echo ""
