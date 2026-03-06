# camera_control_intuitivo

Elixir library for V4L2 camera control with **auto-exposure (PID)**, **MJPEG streaming**, and **full-FPS recording**, using a C NIF and GStreamer. Replaces the legacy Python + OpenCV script in Nerves firmware to reduce image size and remove Python/OpenCV from the rootfs.

---

## Features

- **Native C NIF**: GStreamer pipelines and V4L2 controls run in a C NIF (no Python, no OpenCV).
- **Auto-exposure (MEAN_INTENSITY)**: PID controller in C; gray frames at 4 FPS drive exposure and gain via `ioctl(VIDIOC_S_CTRL)`.
- **USB vs built-in cameras**: Card type from `v4l2-ctl` is used to detect USB cameras (`"usb live camera"`, `"gbx usb live"`) and apply different exposure/gain limits and scaling (e.g. `exp_time/9.5` for USB).
- **Three output branches per camera**:
  1. **Recording (full FPS)**: `tcpserversink` on `127.0.0.1:5000+N` with `gdppay` for external `gst-launch`/Elixir recording to MKV at camera FPS.
  2. **Preview (1 FPS)**: JPEG frames sent to the BEAM via `enif_send`; Elixir HTTP/TCP servers stream MJPEG to web or TCP clients at 1 FPS.
  3. **Auto-exposure**: Decoded gray at 4 FPS to a second `appsink` for PID in C.
- **Device discovery**: `CameraControl.DeviceFinder` resolves `/dev/video*` from `v4l2-ctl --list-devices` using board-specific USB identifiers (RPI4 vs OPCM4), and fetches **Card type** for USB detection.
- **Watchdog**: Each camera GenServer runs a 1 s watchdog: frame timeout (>4 s) or device inode change / device gone triggers restart under the DynamicSupervisor.
- **HTTP (Bandit)**: MJPEG on port 11000, path `/camera/0`, `/camera/1`, `/camera/2`.
- **TCP**: Optional GenServers per camera (e.g. port 6000+N) for MJPEG over raw TCP at 1 FPS.
- **DynamicSupervisor**: Cameras and TCP servers are started/stopped via `CameraControl.Supervisor.start_camera/1`, `start_tcp_server/1`, etc.

---

## Installation

In your `mix.exs`:

```elixir
def deps do
  [
    {:camera_control, git: "https://github.com/intuitivo-ai/camera_control_intuitivo.git", branch: "main"}
  ]
end
```

Or as a local dependency:

```elixir
{:camera_control, path: "../camera_control"}
```

---

## Requirements

- **GStreamer 1.0** and plugins: `gstreamer-1.0`, `gstreamer-app-1.0`, `videoconvertscale` (or `videoconvert`), V4L2, JPEG, `gdppay`/`gdpdepay` (for recording pipeline).
- **Build**: C compiler and `pkg-config` to build the NIF (`elixir_make`).
- **Runtime**: `v4l2-ctl` (and V4L2 kernel support) for device discovery and card type.

---

## Project layout

| Path | Description |
|------|-------------|
| `lib/camera_control.ex` | Main GenServer: starts NIF, keeps last frame, subscribers, watchdog; receives `{:jpeg_frame, id, binary}` from NIF. |
| `lib/camera_control/nif.ex` | NIF module: `start_camera/8`, `stop_camera/1`; loads `priv/camera_nif.so`. |
| `lib/camera_control/device_finder.ex` | Resolves device path and card type from `v4l2-ctl` using RPI4/OPCM4 USB identifier lists. |
| `lib/camera_control/application.ex` | Starts Registry, DynamicSupervisor, and Bandit (HTTP) on port 11000. |
| `lib/camera_control/supervisor.ex` | Helpers: `start_camera/1`, `stop_camera/1`, `start_tcp_server/1`, `stop_tcp_server/1`. |
| `lib/camera_control/http_stream.ex` | Plug: `GET /camera/:id` → chunked MJPEG stream (subscribe to `CameraControl`, 1 FPS throttle). |
| `lib/camera_control/tcp_stream.ex` | GenServer: listens on 6000+id, accepts clients, subscribes to camera, sends MJPEG at 1 FPS. |
| `c_src/camera_nif.c` | GStreamer pipeline (tee → tcpserversink, jpeg appsink, gray appsink), PID + V4L2 ioctl, `enif_send` for JPEG. |
| `Makefile` | Builds `priv/camera_nif.so` with `pkg-config` for GStreamer and Erlang/ERL_EI. |

---

## Usage

1. **Start the application** (e.g. as a dependency of your Nerves app). The app starts the Registry, DynamicSupervisor, and Bandit.

2. **Start cameras** (e.g. from your operations/shim when you receive an “init” command):

   ```elixir
   board_id = "rpi4"  # or "opcm4"
   for id <- 0..2 do
     case CameraControl.Supervisor.start_camera(id: id, board_id: board_id) do
       {:ok, _pid} ->
         CameraControl.Supervisor.start_tcp_server(id: id)
         # Optionally notify operations: successful_0, etc.
       _ -> # failed_0, etc.
     end
   end
   ```

   Cameras resolve their own device path and card type via `DeviceFinder`; optional overrides: `width`, `height`, `fps` (defaults 1280, 720, 30).

3. **Preview (HTTP)**  
   - Base URL: `http://<device>:11000/camera/0` (and `/camera/1`, `/camera/2`).  
   - Response: `multipart/x-mixed-replace; boundary=frame` (MJPEG, ~1 FPS).

4. **Preview (TCP)**  
   - Connect to port `6000 + camera_id`; same MJPEG framing at 1 FPS.

5. **Recording (full FPS)**  
   - Your existing pipeline that uses `tcpclientsrc host=127.0.0.1 port=5000+N` (with gdpdepay, jpegparse, matroskamux, filesink) continues to work; the NIF pipeline exposes `tcpserversink` on ports 5000, 5001, 5002 at camera FPS.

6. **Health**  
   - Your operations process can poll camera liveness via `Registry.lookup(CameraControl.Registry, "camera_0")` (and 1, 2) and report e.g. `health_True_True_True` as before.

---

## Configuration

- **Board identifiers**: RPI4 and OPCM4 USB identifier lists are in `lib/camera_control/device_finder.ex` (`@rpi4_usb_identifiers`, `@opcm4_usb_identifiers`). Adjust if your bus topology differs.
- **USB camera detection**: In C, card type is compared (case-insensitive) to the strings `"usb live camera"` and `"gbx usb live"` to choose exposure/gain scaling and limits; see `USB_CAMERA_IDENTIFIERS` in the original Python script.
- **HTTP port**: 11000 in `lib/camera_control/application.ex` (Bandit).  
- **TCP ports**: 6000 + camera id in `lib/camera_control/tcp_stream.ex`.  
- **Recording ports**: 5000 + camera id in `c_src/camera_nif.c` (tcpserversink).

---

## License

Same as the parent project (Intuitivo).
