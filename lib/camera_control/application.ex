defmodule CameraControl.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :ets.new(:camera_crash_tracker, [:named_table, :public, :set])

    children = [
      {Registry, keys: :unique, name: CameraControl.Registry},
      {DynamicSupervisor, name: CameraControl.CameraSup0, strategy: :one_for_one, max_restarts: 20, max_seconds: 120},
      {DynamicSupervisor, name: CameraControl.CameraSup1, strategy: :one_for_one, max_restarts: 20, max_seconds: 120},
      {DynamicSupervisor, name: CameraControl.CameraSup2, strategy: :one_for_one, max_restarts: 20, max_seconds: 120},
      {DynamicSupervisor, name: CameraControl.TcpSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: CameraControl.HttpSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: CameraControl.AppSupervisor]
    Supervisor.start_link(children, opts)
  end

  def supervisor_for_camera(id) when id in [0, 1, 2] do
    [CameraControl.CameraSup0, CameraControl.CameraSup1, CameraControl.CameraSup2]
    |> Enum.at(id)
  end

  def supervisor_for_camera(_id), do: CameraControl.CameraSup0
end
