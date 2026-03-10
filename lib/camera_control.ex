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
    exposure_counter: 0
  ]

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    name = via_tuple(id)
    GenServer.start_link(__MODULE__, opts, name: name)
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

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    board_id = Keyword.get(opts, :board_id, "rpi4")
    
    # Resolve device path dynamically like the python script
    {path, card_type} = case CameraControl.DeviceFinder.get_device_path(id, board_id) do
      {p, c} -> {p, c}
      p when is_binary(p) -> {p, ""}
      _ -> {nil, ""}
    end

    if is_nil(path) do
      Logger.error("Failed to find device path for camera #{id}")
      # Return ignore or error so supervisor keeps trying
      {:stop, :device_not_found}
    else
      width = Keyword.get(opts, :width, 1280)
      height = Keyword.get(opts, :height, 720)
      fps = Keyword.get(opts, :fps, 30)

      # Get initial inode to detect device reconnection
      inode = case File.stat(path) do
        {:ok, stat} -> stat.inode
        _ -> nil
      end

      case Nif.start_camera(id, board_id, path, card_type, width, height, fps, self()) do
        {:ok, resource} ->
          Logger.info("Camera #{id} started successfully at #{path} (#{card_type})")
          
          # Start watchdog timer
          Process.send_after(self(), :watchdog_check, 1000)

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
          {:stop, reason}
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
    {:noreply, %{state | frame: frame_data, last_frame_time: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info({:ae_data, id, exp_time, gain, mean_intensity}, %{id: id} = state) do
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

    # 1. Check if frame is stuck (> 4000ms)
    if time_since_last_frame > 4000 do
      Logger.error("CameraControl watchdog: frame timeout on camera #{state.id}. Restarting.")
      {:stop, :frame_timeout, state}
    else
      # 2. Check if device inode changed (USB disconnect/reconnect)
      case File.stat(state.path) do
        {:ok, stat} ->
          if stat.inode != state.device_inode do
            Logger.error("CameraControl watchdog: device inode changed on camera #{state.id}. Restarting.")
            {:stop, :device_changed, state}
          else
            Process.send_after(self(), :watchdog_check, 1000)
            {:noreply, state}
          end
        _ ->
          Logger.error("CameraControl watchdog: device gone on camera #{state.id}. Restarting.")
          {:stop, :device_gone, state}
      end
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
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
    Logger.info("Camera #{state.id} terminated: #{inspect(reason)}")
  end
  def terminate(_reason, _state), do: :ok
end
