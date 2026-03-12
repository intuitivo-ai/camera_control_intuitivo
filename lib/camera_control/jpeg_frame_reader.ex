defmodule CameraControl.JpegFrameReader do
  @moduledoc """
  Reads JPEG frames from the primary camera TCP stream using a separate
  gst-launch-1.0 process via Port.

  Pipeline:
    tcpclientsrc → gdpdepay → jpegparse → fdsink

  Parses JPEG frame boundaries using SOI (0xFFD8) and EOI (0xFFD9) markers.
  Sends {:jpeg_frame, camera_id, jpeg_binary} to the CameraControl GenServer.

  Started/stopped alongside the HTTP preview server — only alive while
  HTTP is serving, to avoid wasting CPU when nobody is watching.
  """
  use GenServer
  require Logger

  # JPEG markers
  @soi <<0xFF, 0xD8>>
  @eoi <<0xFF, 0xD9>>

  defstruct [:camera_id, :port, :os_pid, :target_pid, buffer: <<>>, inside_frame: false]

  def start_link(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    name = {:via, Registry, {CameraControl.Registry, "jpeg_reader_#{camera_id}"}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def stop(camera_id) do
    case Registry.lookup(CameraControl.Registry, "jpeg_reader_#{camera_id}") do
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

    Process.flag(:trap_exit, true)

    CameraControl.PidTracker.kill_all(camera_id, :jpeg_reader)

    tcp_port = 5000 + camera_id

    pipeline =
      "exec gst-launch-1.0 -q " <>
      "tcpclientsrc host=127.0.0.1 port=#{tcp_port} " <>
      "! gdpdepay " <>
      "! jpegparse " <>
      "! fdsink"

    port = Port.open(
      {:spawn_executable, "/bin/sh"},
      [:binary, :exit_status, args: ["-c", pipeline]]
    )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    CameraControl.PidTracker.register(camera_id, :jpeg_reader, os_pid)

    Logger.info("JpegFrameReader camera #{camera_id}: started (tcp port #{tcp_port})")

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
    {buffer, inside_frame, state} = extract_frames(buffer, state.inside_frame, state)
    {:noreply, %{state | buffer: buffer, inside_frame: inside_frame}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("JpegFrameReader camera #{state.camera_id}: pipeline exited (status #{status})")
    {:stop, {:pipeline_exit, status}, %{state | port: nil}}
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.os_pid, do: System.cmd("kill", ["-SIGINT", "#{state.os_pid}"], stderr_to_stdout: true)

    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    CameraControl.PidTracker.unregister(state.camera_id, :jpeg_reader)
  end

  # Parse JPEG frames from raw fdsink output using SOI/EOI markers.
  # jpegparse guarantees each buffer is a complete JPEG, but Port may
  # split or merge writes, so we still need marker-based parsing.
  defp extract_frames(buffer, inside_frame, state) do
    cond do
      # Looking for SOI to start a new frame
      not inside_frame ->
        case :binary.match(buffer, @soi) do
          {pos, 2} ->
            # Discard bytes before SOI, keep from SOI onwards
            <<_discard::binary-size(pos), rest::binary>> = buffer
            extract_frames(rest, true, state)

          :nomatch ->
            # No SOI found, discard buffer (keep last byte in case SOI spans chunks)
            keep = max(byte_size(buffer) - 1, 0)
            <<_::binary-size(byte_size(buffer) - keep), tail::binary>> = buffer
            {tail, false, state}
        end

      # Inside a frame, looking for EOI to complete it
      true ->
        case :binary.match(buffer, @eoi) do
          {pos, 2} ->
            # Frame is from start of buffer to end of EOI
            frame_end = pos + 2
            <<frame::binary-size(frame_end), rest::binary>> = buffer
            send(state.target_pid, {:jpeg_frame, state.camera_id, frame})
            # Continue looking for more frames
            extract_frames(rest, false, state)

          :nomatch ->
            # No EOI yet, keep accumulating (but cap buffer at 5MB to avoid leaks)
            if byte_size(buffer) > 5_242_880 do
              Logger.warning("JpegFrameReader camera #{state.camera_id}: buffer overflow, resetting")
              {<<>>, false, state}
            else
              {buffer, true, state}
            end
        end
    end
  end
end
