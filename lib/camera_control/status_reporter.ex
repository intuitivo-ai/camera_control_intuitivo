defmodule CameraControl.StatusReporter do
  @moduledoc """
  Monitors camera processes and reports status changes to a target process
  using the port message format that operations.ex expects.

  Started by PythonShim after camera init, this GenServer monitors each camera
  process and sends `failed_N` / `successful_N` messages when cameras crash
  or recover, ensuring operations.ex always has accurate camera state.

  Also handles automatic recovery: when a camera process has terminated
  permanently (e.g. after hitting max_rapid_crashes), this module will
  periodically attempt to restart it after a cooldown.
  """
  use GenServer
  require Logger

  @check_interval_ms 2_000
  @recovery_cooldown_ms 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop do
    GenServer.stop(__MODULE__, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    target = Keyword.fetch!(opts, :target)
    port = Keyword.fetch!(opts, :port)
    camera_ids = Keyword.get(opts, :camera_ids, [0, 1, 2])
    camera_opts = Keyword.get(opts, :camera_opts, %{})

    state = %{
      target: target,
      port: port,
      camera_ids: camera_ids,
      camera_opts: camera_opts,
      last_status: %{},
      last_recovery_attempt: %{}
    }

    Process.send_after(self(), :check_status, @check_interval_ms)
    {:ok, state}
  end

  @impl true
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

  defp attempt_recovery(state, current_status) do
    now = System.monotonic_time(:millisecond)

    new_recovery_attempts =
      Enum.reduce(state.camera_ids, state.last_recovery_attempt, fn id, acc ->
        alive = Map.get(current_status, id, false)
        process_exists = camera_process_exists?(id)

        if not alive and not process_exists do
          last_attempt = Map.get(acc, id, 0)

          if now - last_attempt > @recovery_cooldown_ms do
            Logger.info("StatusReporter: attempting recovery for camera #{id}")
            CameraControl.reset_crash_count(id)

            opts = Map.get(state.camera_opts, id, [id: id, board_id: "rpi4"])

            case CameraControl.Supervisor.start_camera(opts) do
              {:ok, _} ->
                Logger.info("StatusReporter: camera #{id} restart initiated")

              {:error, reason} ->
                Logger.warning("StatusReporter: camera #{id} restart failed: #{inspect(reason)}")
            end

            Map.put(acc, id, now)
          else
            acc
          end
        else
          if alive, do: Map.delete(acc, id), else: acc
        end
      end)

    %{state | last_recovery_attempt: new_recovery_attempts}
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
