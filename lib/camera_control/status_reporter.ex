defmodule CameraControl.StatusReporter do
  @moduledoc """
  Monitors camera processes and reports status changes to a target process
  using the port message format that operations.ex expects.

  Started under the CameraControl Application supervisor in dormant mode.
  PythonShim activates it via `configure/1` after camera init.

  Sends `failed_N` / `successful_N` messages when cameras crash or recover,
  ensuring operations.ex always has accurate camera state.

  Also handles automatic recovery: when a camera process has terminated
  permanently (e.g. after hitting max_rapid_crashes), this module will
  periodically attempt to restart it after a cooldown.
  """
  use GenServer
  require Logger

  @check_interval_ms 2_000
  @recovery_cooldown_ms 10_000

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :permanent
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Activate StatusReporter with camera configuration."
  def configure(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Deactivate StatusReporter (stops monitoring but keeps process alive)."
  def deactivate do
    GenServer.call(__MODULE__, :deactivate)
  catch
    :exit, _ -> :ok
  end

  @doc "Notify that a USB camera device was physically removed (from NervesUEvent)."
  def notify_device_removed(camera_id) do
    GenServer.cast(__MODULE__, {:device_removed, camera_id})
  catch
    :exit, _ -> :ok
  end

  @doc "Notify that a USB camera device was physically reconnected (from NervesUEvent)."
  def notify_device_added(camera_id) do
    GenServer.cast(__MODULE__, {:device_added, camera_id})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init([]) do
    {:ok, %{active: false}}
  end

  def init(opts) when is_list(opts) and opts != [] do
    state = build_active_state(opts)
    Process.send_after(self(), :check_status, @check_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure, opts}, _from, _state) do
    state = build_active_state(opts)
    Process.send_after(self(), :check_status, @check_interval_ms)
    {:reply, :ok, state}
  end

  def handle_call(:deactivate, _from, _state) do
    {:reply, :ok, %{active: false}}
  end

  # --- USB hotplug event handlers (from NervesUEvent via cams.ex) ---

  @impl true
  def handle_cast({:device_removed, camera_id}, %{active: true} = state) do
    Logger.warning("StatusReporter: USB remove event for camera #{camera_id}")

    if camera_process_exists?(camera_id) do
      try do
        CameraControl.Supervisor.stop_camera(camera_id)
      catch
        _, _ -> :ok
      end
    end

    send(state.target, {state.port, {:data, "failed_#{camera_id}\n"}})
    new_status = Map.put(state.last_status, camera_id, false)
    {:noreply, %{state | last_status: new_status}}
  end

  def handle_cast({:device_added, camera_id}, %{active: true} = state) do
    Logger.info("StatusReporter: USB add event for camera #{camera_id}")

    unless camera_process_exists?(camera_id) do
      CameraControl.reset_crash_count(camera_id)
      opts = Map.get(state.camera_opts, camera_id, [id: camera_id, board_id: "rpi4"])
      # Give device 3s to settle (kernel driver init, /dev/videoN creation)
      Process.send_after(self(), {:attempt_usb_recovery, camera_id, opts}, 3_000)
    end

    {:noreply, state}
  end

  # Inactive — ignore USB events
  def handle_cast({:device_removed, _}, state), do: {:noreply, state}
  def handle_cast({:device_added, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:attempt_usb_recovery, camera_id, opts}, %{active: true} = state) do
    unless camera_process_exists?(camera_id) do
      board_id = Keyword.get(opts, :board_id, "rpi4")

      case CameraControl.DeviceFinder.get_device_path(camera_id, board_id) do
        {_path, _card_type} ->
          case CameraControl.Supervisor.start_camera(opts) do
            {:ok, _} ->
              Logger.info("StatusReporter: camera #{camera_id} recovered via USB hotplug")
              Process.send_after(self(), {:ensure_jpeg_reader, camera_id}, 3_000)

            :ignore ->
              Logger.warning("StatusReporter: camera #{camera_id} USB recovery returned :ignore")

            {:error, {:already_started, _}} ->
              Logger.info("StatusReporter: camera #{camera_id} already running")
              Process.send_after(self(), {:ensure_jpeg_reader, camera_id}, 3_000)

            {:error, reason} ->
              Logger.warning("StatusReporter: camera #{camera_id} USB recovery failed: #{inspect(reason)}")
          end

        _ ->
          Logger.debug("StatusReporter: device not yet visible for camera #{camera_id} after USB add")
      end
    end

    {:noreply, state}
  end

  def handle_info({:attempt_usb_recovery, _, _}, state), do: {:noreply, state}

  # Re-start JpegFrameReader after camera recovery (delayed to let tcpserversink come up)
  def handle_info({:ensure_jpeg_reader, camera_id}, %{active: true} = state) do
    CameraControl.Supervisor.ensure_jpeg_reader(camera_id)
    {:noreply, state}
  end

  def handle_info({:ensure_jpeg_reader, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:check_status, %{active: false} = state) do
    {:noreply, state}
  end

  def handle_info(:check_status, state) do
    new_status =
      Map.new(state.camera_ids, fn id ->
        {id, camera_alive?(id)}
      end)

    Enum.each(state.camera_ids, fn id ->
      prev = Map.get(state.last_status, id)
      curr = Map.get(new_status, id)

      if prev != nil and prev != curr do
        if curr do
          Logger.info("StatusReporter: camera #{id} recovered")
          send(state.target, {state.port, {:data, "successful_#{id}\n"}})
        else
          Logger.warning("StatusReporter: camera #{id} went down")
          send(state.target, {state.port, {:data, "failed_#{id}\n"}})
        end
      end
    end)

    state = attempt_recovery(state, new_status)

    Process.send_after(self(), :check_status, @check_interval_ms)
    {:noreply, %{state | last_status: new_status}}
  end

  defp build_active_state(opts) do
    %{
      active: true,
      target: Keyword.fetch!(opts, :target),
      port: Keyword.fetch!(opts, :port),
      camera_ids: Keyword.get(opts, :camera_ids, [0, 1, 2]),
      camera_opts: Keyword.get(opts, :camera_opts, %{}),
      last_status: %{},
      last_recovery_attempt: %{}
    }
  end

  defp attempt_recovery(state, current_status) do
    now = System.monotonic_time(:millisecond)

    new_recovery_attempts =
      Enum.reduce(state.camera_ids, state.last_recovery_attempt, fn id, acc ->
        try do
          recover_camera(state, id, acc, current_status, now)
        rescue
          e ->
            Logger.warning("StatusReporter: recovery error for camera #{id}: #{inspect(e)}")
            acc
        end
      end)

    %{state | last_recovery_attempt: new_recovery_attempts}
  end

  defp recover_camera(state, id, acc, current_status, now) do
    alive = Map.get(current_status, id, false)
    process_exists = camera_process_exists?(id)

    if not alive and not process_exists do
      last_attempt = Map.get(acc, id, 0)

      if now - last_attempt > @recovery_cooldown_ms do
        opts = Map.get(state.camera_opts, id, [id: id, board_id: "rpi4"])
        board_id = Keyword.get(opts, :board_id, "rpi4")

        case CameraControl.DeviceFinder.get_device_path(id, board_id) do
          {_path, _card_type} ->
            Logger.info("StatusReporter: attempting recovery for camera #{id}")
            CameraControl.reset_crash_count(id)

            result = CameraControl.Supervisor.start_camera(opts)

            case result do
              {:ok, _} ->
                Logger.info("StatusReporter: camera #{id} restart initiated")
                Process.send_after(self(), {:ensure_jpeg_reader, id}, 3_000)
              :ignore ->
                Logger.warning("StatusReporter: camera #{id} init returned ignore (device not ready)")
              {:error, {:already_started, _}} ->
                Logger.info("StatusReporter: camera #{id} already running")
                Process.send_after(self(), {:ensure_jpeg_reader, id}, 3_000)
              {:error, reason} ->
                Logger.warning("StatusReporter: camera #{id} restart failed: #{inspect(reason)}")
            end

          _ ->
            last_log = Process.get({:last_device_not_found_log, id})
            if last_log == nil or now - last_log > 30_000 do
              Logger.debug("StatusReporter: camera #{id} device not found, skipping recovery")
              Process.put({:last_device_not_found_log, id}, now)
            end
        end

        Map.put(acc, id, now)
      else
        acc
      end
    else
      if alive, do: Map.delete(acc, id), else: acc
    end
  end

  defp camera_alive?(id) do
    try do
      GenServer.call(CameraControl.via_tuple(id), :alive?, 500)
    catch
      :exit, _ -> false
    end
  end

  defp camera_process_exists?(id) do
    case Registry.lookup(CameraControl.Registry, "camera_#{id}") do
      [{_pid, _}] -> true
      _ -> false
    end
  end
end
