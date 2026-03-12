defmodule CameraControl.GstPipelineRunner do
  @moduledoc """
  Runs a GStreamer pipeline in a separate OS process via Port.

  This provides crash isolation: if v4l2src segfaults on USB disconnect,
  only the gst-launch-1.0 process dies — the BEAM survives. This is the
  same architecture that worked reliably with the Python/OpenCV approach.

  Each camera gets its own GstPipelineRunner process. The pipeline streams
  JPEG over TCP (tcpserversink) for consumption by TcpStream/HttpStream.
  """
  use GenServer
  require Logger

  @enforce_keys [:camera_id]
  defstruct [
    :camera_id, :path, :card_type, :board_id,
    :width, :height, :fps, :port, :os_pid,
    target_pid: nil,
    status: :stopped
  ]

  def start_link(opts) do
    id = Keyword.fetch!(opts, :camera_id)
    name = {:via, Registry, {CameraControl.Registry, "pipeline_#{id}"}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :camera_id)
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def stop(id) do
    case Registry.lookup(CameraControl.Registry, "pipeline_#{id}") do
      [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    path = Keyword.fetch!(opts, :path)
    card_type = Keyword.get(opts, :card_type, "")
    board_id = Keyword.get(opts, :board_id, "rpi4")
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    fps = Keyword.get(opts, :fps, 30)
    target_pid = Keyword.get(opts, :target_pid)

    # Ensure terminate/2 runs even when parent crashes (sends SIGINT to gst-launch)
    Process.flag(:trap_exit, true)

    # Kill any orphaned gst-launch from a previous run of this camera
    CameraControl.PidTracker.kill_all(camera_id, :pipeline)

    tcp_port = 5000 + camera_id

    pipeline = build_pipeline(path, width, height, fps, tcp_port)

    Logger.info("GstPipelineRunner camera #{camera_id}: launching gst-launch-1.0 at #{path}")

    # Use sh -c to pass the full pipeline string as-is to gst-launch-1.0.
    # Splitting by spaces would break caps like "image/jpeg,width=1280,..."
    cmd = "exec #{gst_launch_path()} -e #{pipeline}"

    port = Port.open(
      {:spawn_executable, "/bin/sh"},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", cmd]
      ]
    )

    # Get the OS pid so we can kill it on cleanup.
    # With `exec`, sh is replaced by gst-launch-1.0 so os_pid IS the gst-launch PID.
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    CameraControl.PidTracker.register(camera_id, :pipeline, os_pid)

    state = %__MODULE__{
      camera_id: camera_id,
      path: path,
      card_type: card_type,
      board_id: board_id,
      width: width,
      height: height,
      fps: fps,
      port: port,
      os_pid: os_pid,
      target_pid: target_pid,
      status: :running
    }

    # Notify the camera GenServer that pipeline is running
    if target_pid do
      send(target_pid, {:pipeline_started, camera_id})
    end

    {:ok, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Log GStreamer stdout/stderr output
    data
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      trimmed = String.trim(line)
      if trimmed != "" do
        if String.contains?(trimmed, "ERROR") or String.contains?(trimmed, "error") do
          Logger.error("GST camera #{state.camera_id}: #{trimmed}")
        else
          Logger.debug("GST camera #{state.camera_id}: #{trimmed}")
        end
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("GstPipelineRunner camera #{state.camera_id}: process exited with status #{status}")

    if state.target_pid do
      send(state.target_pid, {:pipeline_crashed, state.camera_id, status})
    end

    {:stop, {:pipeline_exit, status}, %{state | status: :stopped, port: nil}}
  end

  # Handle EXIT from linked parent (camera GenServer) — stop cleanly
  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    # SIGINT triggers clean EOS shutdown in gst-launch-1.0 -e
    if state.os_pid, do: System.cmd("kill", ["-SIGINT", "#{state.os_pid}"], stderr_to_stdout: true)

    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    CameraControl.PidTracker.unregister(state.camera_id, :pipeline)
    Logger.info("GstPipelineRunner camera #{state.camera_id}: terminated")
  end

  defp build_pipeline(device_path, width, height, fps, tcp_port) do
    "v4l2src device=#{device_path} " <>
    "! image/jpeg,width=#{width},height=#{height},framerate=#{fps}/1 " <>
    "! queue max-size-buffers=200 max-size-bytes=52428800 max-size-time=5000000000 leaky=downstream " <>
    "! gdppay " <>
    "! queue max-size-buffers=200 leaky=downstream " <>
    "! tcpserversink host=127.0.0.1 port=#{tcp_port} sync-method=latest-keyframe recover-policy=keyframe"
  end

  defp gst_launch_path do
    # Find gst-launch-1.0 in PATH
    case System.find_executable("gst-launch-1.0") do
      nil -> "/usr/bin/gst-launch-1.0"
      path -> path
    end
  end
end
