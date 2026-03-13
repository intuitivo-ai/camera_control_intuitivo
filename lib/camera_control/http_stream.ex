defmodule CameraControl.HttpStream do
  @moduledoc """
  Plug that serves MJPEG stream from a Camera Control instance at ~1 FPS.

  Supports two URL patterns:
  - `/` serves the camera configured via `:camera_id` plug option (for per-port instances)
  - `/camera/{id}` serves any camera by ID (for shared-port usage)
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: []} = conn, opts) do
    id = Keyword.get(opts, :camera_id, 0)
    serve_camera(conn, id)
  end

  def call(%Plug.Conn{path_info: ["camera", id_str]} = conn, _opts) do
    case Integer.parse(id_str) do
      {id, ""} -> serve_camera(conn, id)
      _ -> send_resp(conn, 400, "Invalid camera ID")
    end
  end

  def call(conn, _opts) do
    send_resp(conn, 404, "Not Found")
  end

  defp serve_camera(conn, id) do
    conn =
      conn
      |> put_resp_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
      |> put_resp_header("Cache-Control", "no-cache, private")
      |> put_resp_header("Access-Control-Allow-Origin", "*")
      |> put_resp_header("Pragma", "no-cache")
      |> send_chunked(200)

    try do
      CameraControl.subscribe(id)
      stream_loop(conn, id)
    catch
      _, _ ->
        try do
          CameraControl.unsubscribe(id)
        catch
          _, _ -> :ok
        end
        conn
    end
  end

  # Close connection after 30s without frames (camera likely dead)
  @max_empty_cycles 30

  defp stream_loop(conn, id, empty_cycles \\ 0)

  defp stream_loop(conn, id, empty_cycles) when empty_cycles >= @max_empty_cycles do
    Logger.warning("HttpStream camera #{id}: no frames for #{@max_empty_cycles}s, closing connection")
    CameraControl.unsubscribe(id)
    conn
  end

  defp stream_loop(conn, id, empty_cycles) do
    Process.sleep(1000)

    frame_data = drain_latest_frame(nil)

    if frame_data do
      header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: #{byte_size(frame_data)}\r\n\r\n"

      case Plug.Conn.chunk(conn, [header, frame_data, "\r\n"]) do
        {:ok, conn} ->
          stream_loop(conn, id, 0)

        {:error, _reason} ->
          CameraControl.unsubscribe(id)
          conn
      end
    else
      stream_loop(conn, id, empty_cycles + 1)
    end
  end

  defp drain_latest_frame(latest) do
    receive do
      {:jpeg_frame, _id, frame_data} ->
        drain_latest_frame(frame_data)
    after
      0 -> latest
    end
  end
end
