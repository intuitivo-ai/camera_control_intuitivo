defmodule CameraControl.Supervisor do
  @moduledoc """
  Helper module to start cameras under per-camera DynamicSupervisors.
  Each camera has its own supervisor so one unstable camera cannot
  exhaust the restart budget of the others.
  """

  def start_camera(opts) do
    id = Keyword.fetch!(opts, :id)
    sup = CameraControl.Application.supervisor_for_camera(id)

    DynamicSupervisor.start_child(sup, {CameraControl, opts})
  end

  def stop_camera(id) do
    case Registry.lookup(CameraControl.Registry, "camera_#{id}") do
      [{pid, _}] ->
        sup = CameraControl.Application.supervisor_for_camera(id)
        DynamicSupervisor.terminate_child(sup, pid)
      _ ->
        :ok
    end
  end

  def start_tcp_server(opts) do
    id = Keyword.fetch!(opts, :id)
    ensure_jpeg_reader(id)

    DynamicSupervisor.start_child(
      CameraControl.TcpSupervisor,
      {CameraControl.TcpStream, opts}
    )
  end

  def stop_tcp_server(id) do
    case Registry.lookup(CameraControl.Registry, "tcp_#{id}") do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(CameraControl.TcpSupervisor, pid)
      _ ->
        :ok
    end

    # Stop JPEG reader only if HTTP isn't also using it for this camera
    http_port = 11000 + id
    http_active = port_listening?(http_port)

    unless http_active do
      CameraControl.JpegFrameReader.stop(id)
    end
  end

  def start_http_server(camera_id, app_dir) do
    port = 11000 + camera_id

    scheme_opts =
      if app_dir do
        certfile = Path.join([app_dir, "priv", "firmware-chain.crt"])
        keyfile = Path.join([app_dir, "priv", "firmware.key"])

        if File.exists?(certfile) and File.exists?(keyfile) do
          [scheme: :https, certfile: certfile, keyfile: keyfile, http_2_options: [enabled: false]]
        else
          [scheme: :http]
        end
      else
        [scheme: :http]
      end

    # Explicitly bind to 0.0.0.0 so it's accessible from outside, just like Python's ('0.0.0.0', PORT)
    opts = Keyword.merge([plug: {CameraControl.HttpStream, [camera_id: camera_id]}, port: port, ip: {0, 0, 0, 0}], scheme_opts)

    # Start JPEG frame reader to feed CameraControl GenServer with {:jpeg_frame} messages.
    # HttpStream/TcpStream subscribe to CameraControl and need these frames.
    ensure_jpeg_reader(camera_id)

    case DynamicSupervisor.start_child(
           CameraControl.HttpSupervisor,
           {Bandit, opts}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrinuse}}} -> :ok
      {:error, {:shutdown, {:failed_to_start_child, _, :eaddrinuse}}} -> :ok
      error ->
        require Logger
        Logger.error("Failed to start HTTP server for camera #{camera_id}: #{inspect(error)}")
        error
    end
  end

  def start_all_http(app_dir \\ nil) do
    children = DynamicSupervisor.which_children(CameraControl.HttpSupervisor)
    if length(children) >= 3, do: :ok, else: Enum.each(0..2, &start_http_server(&1, app_dir))
  end

  def stop_all_http do
    # Stop JPEG frame readers first (only if no TCP servers are using them)
    Enum.each(0..2, fn id ->
      tcp_alive = case Registry.lookup(CameraControl.Registry, "tcp_#{id}") do
        [{_, _}] -> true
        _ -> false
      end

      unless tcp_alive do
        CameraControl.JpegFrameReader.stop(id)
      end
    end)

    DynamicSupervisor.which_children(CameraControl.HttpSupervisor)
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(CameraControl.HttpSupervisor, pid)
    end)

    :ok
  end

  @doc """
  Ensures a JpegFrameReader is running for the given camera.
  No-op if already started or if the camera GenServer isn't alive.
  Called by start_http_server and start_tcp_server.
  """
  def ensure_jpeg_reader(camera_id) do
    case Registry.lookup(CameraControl.Registry, "jpeg_reader_#{camera_id}") do
      [{_, _}] ->
        # Already running
        :ok

      _ ->
        target_pid = CameraControl.via_tuple(camera_id) |> GenServer.whereis()

        if target_pid do
          case CameraControl.JpegFrameReader.start_link(camera_id: camera_id, target_pid: target_pid) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
            error -> error
          end
        else
          :ok
        end
    end
  end

  defp port_listening?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true
      {:error, _} ->
        false
    end
  end
end
