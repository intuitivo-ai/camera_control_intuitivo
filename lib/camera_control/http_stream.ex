defmodule CameraControl.HttpStream do
  @moduledoc """
  A plug to serve MJPEG stream from a Camera Control instance.
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["camera", id_str]} = conn, _opts) do
    id = String.to_integer(id_str)

    conn =
      conn
      |> put_resp_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
      |> put_resp_header("Cache-Control", "no-cache, private")
      |> put_resp_header("Pragma", "no-cache")
      |> send_chunked(200)

    try do
      CameraControl.subscribe(id)
      stream_loop(conn)
    catch
      _, _ ->
        CameraControl.unsubscribe(id)
        conn
    end
  end

  def call(conn, _opts) do
    send_resp(conn, 404, "Not Found")
  end

  defp stream_loop(conn) do
    receive do
      {:jpeg_frame, _id, frame_data} ->
        header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: #{byte_size(frame_data)}\r\n\r\n"

        case Plug.Conn.chunk(conn, [header, frame_data, "\r\n"]) do
          {:ok, conn} ->
            # throttle
            Process.sleep(100)
            stream_loop(conn)

          {:error, _reason} ->
            conn
        end

      _ ->
        stream_loop(conn)
    end
  end
end
