defmodule CameraControl.TcpStream do
  use GenServer
  require Logger

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    port = Keyword.get(opts, :port, 6000 + id)
    GenServer.start_link(__MODULE__, {id, port}, name: {:via, Registry, {CameraControl.Registry, "tcp_#{id}"}})
  end

  @impl true
  def init({id, port}) do
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
        pid = spawn(fn -> client_loop(client, state.id) end)
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

  defp client_loop(client, id) do
    CameraControl.subscribe(id)
    stream_loop(client)
  after
    try do
      CameraControl.unsubscribe(id)
    catch
      _, _ -> :ok
    end
    :gen_tcp.close(client)
  end

  defp stream_loop(client) do
    Process.sleep(1000)

    frame_data = drain_latest_frame(nil)

    if frame_data do
      header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: #{byte_size(frame_data)}\r\n\r\n"
      case :gen_tcp.send(client, [header, frame_data, "\r\n"]) do
        :ok ->
          stream_loop(client)
        {:error, _} ->
          :ok
      end
    else
      stream_loop(client)
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
