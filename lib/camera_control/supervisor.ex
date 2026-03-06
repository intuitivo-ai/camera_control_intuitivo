defmodule CameraControl.Supervisor do
  @moduledoc """
  Helper module to start cameras under the DynamicSupervisor.
  """
  
  def start_camera(opts) do
    DynamicSupervisor.start_child(
      CameraControl.CameraSupervisor,
      {CameraControl, opts}
    )
  end

  def stop_camera(id) do
    case Registry.lookup(CameraControl.Registry, "camera_#{id}") do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(CameraControl.CameraSupervisor, pid)
      _ ->
        :ok
    end
  end

  def start_tcp_server(opts) do
    DynamicSupervisor.start_child(
      CameraControl.CameraSupervisor,
      {CameraControl.TcpStream, opts}
    )
  end

  def stop_tcp_server(id) do
    case Registry.lookup(CameraControl.Registry, "tcp_#{id}") do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(CameraControl.CameraSupervisor, pid)
      _ ->
        :ok
    end
  end
end