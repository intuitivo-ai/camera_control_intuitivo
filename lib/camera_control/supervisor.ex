defmodule CameraControl.Supervisor do
  @moduledoc """
  Helper module to start cameras under per-camera DynamicSupervisors.
  Each camera has its own supervisor so one unstable camera cannot
  exhaust the restart budget of the others.
  """

  def start_camera(opts) do
    id = Keyword.fetch!(opts, :id)
    sup = CameraControl.Application.supervisor_for_camera(id)

    DynamicSupervisor.start_child(sup, {CameraControl, opts})
  end

  def stop_camera(id) do
    case Registry.lookup(CameraControl.Registry, "camera_#{id}") do
      [{pid, _}] ->
        sup = CameraControl.Application.supervisor_for_camera(id)
        DynamicSupervisor.terminate_child(sup, pid)
      _ ->
        :ok
    end
  end

  def start_tcp_server(opts) do
    DynamicSupervisor.start_child(
      CameraControl.TcpSupervisor,
      {CameraControl.TcpStream, opts}
    )
  end

  def stop_tcp_server(id) do
    case Registry.lookup(CameraControl.Registry, "tcp_#{id}") do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(CameraControl.TcpSupervisor, pid)
      _ ->
        :ok
    end
  end
end
