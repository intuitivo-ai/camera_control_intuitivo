defmodule CameraControl.AeFrameReader do
  @moduledoc """
  Reads downscaled grayscale frames from the primary camera TCP stream
  using a separate gst-launch-1.0 process via Port.

  Pipeline:
    tcpclientsrc → gdpdepay → jpegdec → videoconvert → GRAY8 → videoscale(160x120) → fdsink

  Each frame is exactly @frame_size bytes (160 * 120 = 19,200).
  Sends {:ae_frame, camera_id, grayscale_binary} to the target process.
  """
  use GenServer
  require Logger

  @analysis_width 160
  @analysis_height 120
  @frame_size @analysis_width * @analysis_height

  defstruct [:camera_id, :port, :os_pid, :target_pid, buffer: <<>>]

  def start_link(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    name = {:via, Registry, {CameraControl.Registry, "ae_reader_#{camera_id}"}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def stop(camera_id) do
    case Registry.lookup(CameraControl.Registry, "ae_reader_#{camera_id}") do
      [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    target_pid = Keyword.fetch!(opts, :target_pid)
    tcp_port = 5000 + camera_id

    pipeline =
      "exec gst-launch-1.0 -q " <>
      "tcpclientsrc host=127.0.0.1 port=#{tcp_port} " <>
      "! gdpdepay " <>
      "! jpegdec " <>
      "! videoconvert " <>
      "! video/x-raw,format=GRAY8 " <>
      "! videoscale " <>
      "! video/x-raw,width=#{@analysis_width},height=#{@analysis_height} " <>
      "! videorate " <>
      "! video/x-raw,framerate=4/1 " <>
      "! fdsink"

    port = Port.open(
      {:spawn_executable, "/bin/sh"},
      [:binary, :exit_status, args: ["-c", pipeline]]
    )

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    Logger.info("AeFrameReader camera #{camera_id}: started (tcp port #{tcp_port}, #{@analysis_width}x#{@analysis_height} GRAY8 @ 4fps)")

    {:ok, %__MODULE__{
      camera_id: camera_id,
      port: port,
      os_pid: os_pid,
      target_pid: target_pid
    }}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {buffer, state} = extract_frames(buffer, state)
    {:noreply, %{state | buffer: buffer}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("AeFrameReader camera #{state.camera_id}: pipeline exited (status #{status})")
    {:stop, {:pipeline_exit, status}, %{state | port: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end
  end

  defp extract_frames(buffer, state) when byte_size(buffer) >= @frame_size do
    <<frame::binary-size(@frame_size), rest::binary>> = buffer
    send(state.target_pid, {:ae_frame, state.camera_id, frame})
    extract_frames(rest, state)
  end

  defp extract_frames(buffer, state), do: {buffer, state}
end
