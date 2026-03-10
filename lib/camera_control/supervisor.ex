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
    DynamicSupervisor.which_children(CameraControl.HttpSupervisor)
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(CameraControl.HttpSupervisor, pid)
    end)

    :ok
  end
end
