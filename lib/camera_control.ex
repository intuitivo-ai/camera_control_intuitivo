defmodule CameraControl do
  use GenServer
  require Logger

  alias CameraControl.GstPipelineRunner
  alias CameraControl.AutoExposure

  @enforce_keys [:id, :board_id]
  defstruct [
    :id, :board_id, :path, :card_type, :width, :height, :fps,
    :pipeline_pid, :ae_pid, :frame, :device_inode, :last_frame_time,
    subscribers: [],
    recording: false,
    recording_base: nil,
    exposure_data: [],
    exposure_counter: 0
  ]

  @device_retry_delay_ms 2_000
  @device_max_retries 5
  @base_backoff_ms 3_000
  @max_backoff_ms 30_000
  @max_rapid_crashes 8
  @crash_window_ms 120_000
  @heartbeat_interval_ms 2_000

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    name = via_tuple(id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def via_tuple(id), do: {:via, Registry, {CameraControl.Registry, "camera_#{id}"}}

  def subscribe(id) do
    GenServer.call(via_tuple(id), {:subscribe, self()})
  end

  def unsubscribe(id) do
    GenServer.cast(via_tuple(id), {:unsubscribe, self()})
  end

  def get_current_frame(id) do
    GenServer.call(via_tuple(id), :get_frame)
  end

  def set_controls(id, target_intensity, max_exp, min_exp, max_gain, min_gain, gain_step, dec_gain, inc_gain) do
    GenServer.call(via_tuple(id), {:set_controls, target_intensity, max_exp, min_exp, max_gain, min_gain, gain_step, dec_gain, inc_gain})
  end

  def start_recording(id, file_location) do
    base = file_location |> String.split("/raw/") |> List.first()
    GenServer.cast(via_tuple(id), {:start_recording, base})
  end

  def stop_recording(id) do
    GenServer.cast(via_tuple(id), :stop_recording)
  end

  def reset_crash_count(id) do
    try do
      :ets.delete(:camera_crash_tracker, id)
    catch
      _, _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    board_id = Keyword.get(opts, :board_id, "rpi4")

    crash_count = recent_crash_count(id)

    if crash_count >= @max_rapid_crashes do
      Logger.error("Camera #{id}: too many crashes (#{crash_count}/#{@max_rapid_crashes}), giving up to StatusReporter")
      :ignore
    else
      if crash_count > 0 do
        backoff = min(@max_backoff_ms, @base_backoff_ms * round(:math.pow(2, min(crash_count - 1, 4))))
        Logger.info("Camera #{id}: waiting #{div(backoff, 1000)}s before retry (crash #{crash_count}/#{@max_rapid_crashes})")
        Process.sleep(backoff)
      end

      {path, card_type} = find_device_with_retries(id, board_id, @device_max_retries)

      cond do
        is_nil(path) ->
          Logger.warning("Camera #{id}: device not found after #{@device_max_retries} attempts")
          :ignore

        not wait_device_ready(path, id) ->
          Logger.warning("Camera #{id}: device #{path} not ready, will retry via StatusReporter")
          :ignore

        true ->
          width = Keyword.get(opts, :width, 1280)
          height = Keyword.get(opts, :height, 720)
          fps = Keyword.get(opts, :fps, 30)

          inode = case File.stat(path) do
            {:ok, stat} -> stat.inode
            _ -> nil
          end

          # Launch GStreamer pipeline in a separate OS process
          pipeline_opts = [
            camera_id: id,
            path: path,
            card_type: card_type,
            board_id: board_id,
            width: width,
            height: height,
            fps: fps,
            target_pid: self()
          ]

          case GstPipelineRunner.start_link(pipeline_opts) do
            {:ok, pipeline_pid} ->
              Process.monitor(pipeline_pid)
              Logger.info("Camera #{id} started successfully at #{path} (#{card_type})")
              clear_crash_history_on_success(id)

              # Initialize V4L2 controls now that device is confirmed working
              CameraControl.V4L2.init_controls(path, board_id, card_type)

              # Start watchdog and heartbeat
              Process.send_after(self(), :watchdog_check, 4000)
              Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

              {:ok, %__MODULE__{
                id: id,
                board_id: board_id,
                path: path,
                card_type: card_type,
                width: width,
                height: height,
                fps: fps,
                pipeline_pid: pipeline_pid,
                device_inode: inode,
                last_frame_time: System.monotonic_time(:millisecond)
              }}

            {:error, reason} ->
              Logger.error("Failed to start camera #{id} at #{path}: #{inspect(reason)}")
              record_crash(id)
              {:stop, reason}
          end
      end
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_call(:get_frame, _from, state) do
    {:reply, state.frame, state}
  end

  @impl true
  def handle_call(:alive?, _from, state) do
    {:reply, state.pipeline_pid != nil, state}
  end

  @impl true
  def handle_call({:set_controls, ti, max_e, min_e, max_g, min_g, gs, dec_g, inc_g}, _from, state) do
    params = %{
      target_intensity: ti,
      max_exp_us: max_e,
      min_exp_us: min_e,
      max_gain: max_g,
      min_gain: min_g,
      gain_change_step: gs,
      dec_gain_exp_us: dec_g,
      inc_gain_exp_us: inc_g
    }

    # Start AutoExposure if not yet running, or update its params
    state =
      if state.ae_pid do
        AutoExposure.update_controls(state.id, params)
        state
      else
        case start_auto_exposure(state) do
          {:ok, ae_pid} ->
            AutoExposure.update_controls(state.id, params)
            %{state | ae_pid: ae_pid}
          _ ->
            state
        end
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast({:start_recording, base}, state) do
    metadata_dir = Path.join(base, "metadata")
    File.mkdir_p(metadata_dir)
    {:noreply, %{state | recording: true, recording_base: base, exposure_data: [], exposure_counter: 0}}
  end

  @impl true
  def handle_cast(:stop_recording, state) do
    if state.recording and state.recording_base do
      save_exposure_log(state)
    end
    {:noreply, %{state | recording: false, recording_base: nil, exposure_data: [], exposure_counter: 0}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Periodic heartbeat — schedule next one
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ae_update, id, exp_us, gain, mean_intensity}, %{id: id} = state) do
    state =
      if state.recording do
        counter = state.exposure_counter + 1
        entry = {counter, exp_us, gain, mean_intensity}
        %{state | exposure_data: [entry | state.exposure_data], exposure_counter: counter}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:jpeg_frame, id, frame_data}, %{id: id} = state) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:jpeg_frame, id, frame_data})
    end)

    {:noreply, %{state | frame: frame_data, last_frame_time: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info({:pipeline_started, id}, %{id: id} = state) do
    Logger.info("Camera #{id}: GStreamer pipeline running in separate process")
    {:noreply, state}
  end

  @impl true
  def handle_info({:pipeline_crashed, id, exit_status}, %{id: id} = state) do
    Logger.error("Camera #{id}: GStreamer pipeline process crashed (exit #{exit_status})")
    {:stop, {:pipeline_crashed, exit_status}, %{state | pipeline_pid: nil}}
  end

  @impl true
  def handle_info(:watchdog_check, state) do
    case File.stat(state.path) do
      {:ok, stat} ->
        if stat.inode != state.device_inode do
          Logger.error("CameraControl watchdog: device inode changed on camera #{state.id}. Restarting.")
          {:stop, {:watchdog, :device_changed}, state}
        else
          Process.send_after(self(), :watchdog_check, 2000)
          {:noreply, state}
        end
      _ ->
        Logger.error("CameraControl watchdog: device gone on camera #{state.id}. Restarting.")
        {:stop, {:watchdog, :device_gone}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{ae_pid: pid} = state) when pid != nil do
    Logger.warning("Camera #{state.id}: auto-exposure process died: #{inspect(reason)}, will restart on next set_controls")
    {:noreply, %{state | ae_pid: nil}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{pipeline_pid: pid} = state) when pid != nil do
    Logger.warning("Camera #{state.id}: pipeline runner process died: #{inspect(reason)}")
    {:stop, {:pipeline_down, reason}, %{state | pipeline_pid: nil}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  defp start_auto_exposure(state) do
    ae_opts = [
      camera_id: state.id,
      device_path: state.path,
      board_id: state.board_id,
      card_type: state.card_type,
      camera_pid: self()
    ]

    case AutoExposure.start_link(ae_opts) do
      {:ok, pid} ->
        Process.monitor(pid)
        Logger.info("Camera #{state.id}: auto-exposure started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("Camera #{state.id}: failed to start auto-exposure: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp wait_device_ready(path, id, attempts \\ 5)
  defp wait_device_ready(_path, _id, 0), do: false

  defp wait_device_ready(path, id, attempts) do
    case System.cmd("v4l2-ctl", ["--device", path, "--get-fmt-video"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ ->
        Process.sleep(500)
        wait_device_ready(path, id, attempts - 1)
    end
  end

  defp find_device_with_retries(id, board_id, max_retries) do
    do_find_device(id, board_id, max_retries)
  end

  defp do_find_device(_id, _board_id, 0), do: {nil, ""}

  defp do_find_device(id, board_id, retries_left) do
    case CameraControl.DeviceFinder.get_device_path(id, board_id) do
      {p, c} -> {p, c}
      _ ->
        Process.sleep(@device_retry_delay_ms)
        do_find_device(id, board_id, retries_left - 1)
    end
  end

  defp record_crash(id) do
    now = System.monotonic_time(:millisecond)
    timestamps = case :ets.lookup(:camera_crash_tracker, id) do
      [{^id, ts}] -> ts
      _ -> []
    end
    cutoff = now - @crash_window_ms
    updated = [now | Enum.filter(timestamps, &(&1 > cutoff))]
    :ets.insert(:camera_crash_tracker, {id, updated})
  rescue
    _ -> :ok
  end

  defp recent_crash_count(id) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @crash_window_ms
    case :ets.lookup(:camera_crash_tracker, id) do
      [{^id, timestamps}] ->
        Enum.count(timestamps, &(&1 > cutoff))
      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp clear_crash_history_on_success(id) do
    try do
      :ets.delete(:camera_crash_tracker, id)
    catch
      _, _ -> :ok
    end
  end

  defp save_exposure_log(state) do
    path = Path.join([state.recording_base, "metadata", "exposure_gain_cam#{state.id}.txt"])

    content =
      state.exposure_data
      |> Enum.reverse()
      |> Enum.map(fn {counter, exp, gain, mean} ->
        "#{counter},#{exp},#{gain},#{Float.round(mean * 1.0, 4)}"
      end)
      |> Enum.join("\n")

    case File.write(path, content <> "\n") do
      :ok -> Logger.info("Exposure log saved to #{path}")
      {:error, reason} -> Logger.error("Error saving exposure log: #{inspect(reason)}")
    end
  end

  @impl true
  def terminate(reason, state) do
    if state.recording and state.recording_base do
      save_exposure_log(state)
    end

    # Stop auto-exposure and pipeline runner
    if state.ae_pid, do: AutoExposure.stop(state.id)

    if state.pipeline_pid && Process.alive?(state.pipeline_pid) do
      GstPipelineRunner.stop(state.id)
    end

    record_crash(state.id)
    Logger.info("Camera #{state.id} terminated: #{inspect(reason)}")
  end
end
