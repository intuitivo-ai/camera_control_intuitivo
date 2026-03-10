defmodule CameraControl.StatusReporter do
  @moduledoc """
  Monitors camera processes and reports status changes to a target process
  using the port message format that operations.ex expects.

  Started by PythonShim after camera init, this GenServer monitors each camera
  process and sends `failed_N` / `successful_N` messages when cameras crash
  or recover, ensuring operations.ex always has accurate camera state.
  """
  use GenServer
  require Logger

  @check_interval_ms 2_000

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

    state = %{
      target: target,
      port: port,
      camera_ids: camera_ids,
      last_status: %{}
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

    Process.send_after(self(), :check_status, @check_interval_ms)
    {:noreply, %{state | last_status: new_status}}
  end

  defp camera_alive?(id) do
    try do
      GenServer.call(CameraControl.via_tuple(id), :alive?, 500)
    catch
      :exit, _ -> false
    end
  end
end
