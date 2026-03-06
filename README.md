# camera_control_intuitivo

Librería Elixir para control de cámaras V4L2 con auto-exposición (PID) y streaming MJPEG, usando NIF en C con GStreamer. Sustituye el script Python + OpenCV en el firmware Nerves para reducir el tamaño de la imagen.

## Instalación

En tu `mix.exs`:

```elixir
def deps do
  [
    {:camera_control, git: "https://github.com/intuitivo-ai/camera_control_intuitivo.git", branch: "main"}
  ]
end
```

O como dependencia local:

```elixir
{:camera_control, path: "../camera_control"}
```

## Requisitos

- GStreamer 1.0 y plugins (gstreamer-app-1.0, videoconvert, v4l2, jpeg)
- Compilador C y `pkg-config` para construir el NIF

## Uso

La aplicación arranca bajo un supervisor; las cámaras se inician vía `CameraControl.start_link/1` con opciones `id`, `board_id`, `path`, `width`, `height`, `fps`. Los frames JPEG se envían al proceso registrado; los servidores HTTP (Bandit) y TCP sirven streams MJPEG a clientes suscritos.
