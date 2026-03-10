defmodule CameraControl do
  use GenServer
  require Logger

  alias CameraControl.Nif

  @enforce_keys [:id, :board_id]
  defstruct [
    :id, :board_id, :path, :card_type, :width, :height, :fps,
    :resource, :frame, :device_inode, :last_frame_time,
    subscribers: [],
    recording: false,
    recording_base: nil,
    exposure_data: [],
    exposure_counter: 0,
    last_applied_exp: 0,
    last_applied_gain: -1,
    controls_initialized: false
  ]

  @device_retry_delay_ms 2_000
  @device_max_retries 5
  @base_backoff_ms 3_000
  @max_backoff_ms 30_000
  @max_rapid_crashes 8
  @crash_window_ms 120_000

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
      Logger.error("Camera #{id}: too many crashes (#{crash_count}/#{@max_rapid_crashes}), giving up")
      {:stop, :normal}
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
          record_crash(id)
          {:stop, :device_not_found}

        not wait_device_ready(path, id) ->
          Logger.error("Camera #{id}: device #{path} never became ready")
          record_crash(id)
          {:stop, :device_not_ready}

        true ->
          width = Keyword.get(opts, :width, 1280)
          height = Keyword.get(opts, :height, 720)
          fps = Keyword.get(opts, :fps, 30)

          inode = case File.stat(path) do
            {:ok, stat} -> stat.inode
            _ -> nil
          end

          case Nif.start_camera(id, board_id, path, card_type, width, height, fps, self()) do
            {:ok, resource} ->
              Logger.info("Camera #{id} started successfully at #{path} (#{card_type})")
              Process.send_after(self(), :watchdog_check, 4000)

              {:ok, %__MODULE__{
                id: id,
                board_id: board_id,
                path: path,
                card_type: card_type,
                width: width,
                height: height,
                fps: fps,
                resource: resource,
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
    {:reply, state.resource != nil, state}
  end

  @impl true
  def handle_call({:set_controls, target_intensity, max_exp, min_exp, max_gain, min_gain, gain_step, dec_gain, inc_gain}, _from, state) do
    result = Nif.set_controls(state.resource, target_intensity / 1.0, max_exp, min_exp, max_gain, min_gain, gain_step, dec_gain, inc_gain)
    {:reply, result, state}
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
  def handle_info({:jpeg_frame, id, frame_data}, %{id: id} = state) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:jpeg_frame, id, frame_data})
    end)

    state =
      if not state.controls_initialized do
        Logger.info("Camera #{id}: first frame received, initializing V4L2 controls")
        CameraControl.V4L2.init_controls(state.path, state.board_id, state.card_type)
        %{state | controls_initialized: true}
      else
        state
      end

    clear_crash_history_on_success(id)
    {:noreply, %{state | frame: frame_data, last_frame_time: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info({:ae_data, id, exp_time, gain, mean_intensity}, %{id: id} = state) do
    state = apply_ae_controls(state, exp_time, gain)

    if state.recording do
      counter = state.exposure_counter + 1
      entry = {counter, exp_time, gain, mean_intensity}
      {:noreply, %{state | exposure_data: [entry | state.exposure_data], exposure_counter: counter}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:watchdog_check, state) do
    current_time = System.monotonic_time(:millisecond)
    time_since_last_frame = current_time - state.last_frame_time

    # Increase timeout to 8000ms. Some cameras take longer to negotiate UVC
    # and start streaming their first frame after being opened by GStreamer.
    if time_since_last_frame > 12000 do
      Logger.error("CameraControl watchdog: frame timeout on camera #{state.id}. Restarting.")
      # Exit with an error tuple so the :transient supervisor restarts us
      exit({:shutdown, :frame_timeout})
    else
      case File.stat(state.path) do
        {:ok, stat} ->
          if stat.inode != state.device_inode do
            Logger.error("CameraControl watchdog: device inode changed on camera #{state.id}. Restarting.")
            exit({:shutdown, :device_changed})
          else
            Process.send_after(self(), :watchdog_check, 1000)
            {:noreply, state}
          end
        _ ->
          Logger.error("CameraControl watchdog: device gone on camera #{state.id}. Restarting.")
          exit({:shutdown, :device_gone})
      end
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  defp apply_ae_controls(state, exp_time, gain) do
    exp_changed = exp_time != state.last_applied_exp
    gain_changed = gain != state.last_applied_gain

    if exp_changed do
      CameraControl.V4L2.apply_exposure(state.path, state.board_id, state.card_type, exp_time)
    end

    if gain_changed do
      CameraControl.V4L2.apply_gain(state.path, state.board_id, gain)
    end

    %{state | last_applied_exp: exp_time, last_applied_gain: gain}
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
  def terminate(reason, %{resource: resource} = state) when not is_nil(resource) do
    if state.recording and state.recording_base do
      save_exposure_log(state)
    end
    Nif.stop_camera(resource)
    record_crash(state.id)
    Logger.info("Camera #{state.id} terminated: #{inspect(reason)}")
  end
  def terminate(_reason, _state), do: :ok
end
