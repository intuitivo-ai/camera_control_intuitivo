defmodule CameraControl.TcpStream do
  use GenServer
  require Logger

  # Close connection after 30s without frames (camera likely dead)
  @max_empty_cycles 30

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    port = Keyword.get(opts, :port, 6000 + id)
    GenServer.start_link(__MODULE__, {id, port}, name: {:via, Registry, {CameraControl.Registry, "tcp_#{id}"}})
  end

  @impl true
  def init({id, port}) do
    Process.flag(:trap_exit, true)

    case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("TCP server started for camera #{id} on port #{port}")
        send(self(), :accept)
        {:ok, %{id: id, socket: socket}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.socket, 1000) do
      {:ok, client} ->
        pid = spawn_link(fn -> client_loop(client, state.id) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("TCP accept failed: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  # Client processes exit when GenServer dies (spawn_link), ignore their exits
  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp client_loop(client, id) do
    CameraControl.subscribe(id)
    stream_loop(client, id, 0)
  after
    try do
      CameraControl.unsubscribe(id)
    catch
      _, _ -> :ok
    end
    :gen_tcp.close(client)
  end

  defp stream_loop(_client, id, empty_cycles) when empty_cycles >= @max_empty_cycles do
    Logger.warning("TcpStream camera #{id}: no frames for #{@max_empty_cycles}s, closing connection")
    :ok
  end

  defp stream_loop(client, id, empty_cycles) do
    Process.sleep(1000)

    frame_data = drain_latest_frame(nil)

    if frame_data do
      header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: #{byte_size(frame_data)}\r\n\r\n"
      case :gen_tcp.send(client, [header, frame_data, "\r\n"]) do
        :ok ->
          stream_loop(client, id, 0)
        {:error, _} ->
          :ok
      end
    else
      stream_loop(client, id, empty_cycles + 1)
    end
  end

  defp drain_latest_frame(latest) do
    receive do
      {:jpeg_frame, _id, frame_data} ->
        drain_latest_frame(frame_data)
    after
      0 -> latest
    end
  end
end
