defmodule CameraControl do
  use GenServer
  require Logger

  alias CameraControl.Nif

  @enforce_keys [:id, :board_id, :path]
  defstruct [:id, :board_id, :path, :width, :height, :fps, :resource, :frame, subscribers: []]

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

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    board_id = Keyword.get(opts, :board_id, "rpi4")
    path = Keyword.fetch!(opts, :path)
    width = Keyword.get(opts, :width, 1280)
    height = Keyword.get(opts, :height, 720)
    fps = Keyword.get(opts, :fps, 30)

    case Nif.start_camera(id, board_id, path, width, height, fps, self()) do
      {:ok, resource} ->
        Logger.info("Camera #{id} started successfully at #{path}")
        {:ok, %__MODULE__{
          id: id,
          board_id: board_id,
          path: path,
          width: width,
          height: height,
          fps: fps,
          resource: resource
        }}

      {:error, reason} ->
        Logger.error("Failed to start camera #{id}: #{inspect(reason)}")
        {:stop, reason}
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
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({:jpeg_frame, id, frame_data}, %{id: id} = state) do
    # Broadcoast frame to all subscribers
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:jpeg_frame, id, frame_data})
    end)
    {:noreply, %{state | frame: frame_data}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  @impl true
  def terminate(_reason, %{resource: resource}) when not is_nil(resource) do
    Nif.stop_camera(resource)
  end
  def terminate(_reason, _state), do: :ok
end
