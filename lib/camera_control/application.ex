defmodule CameraControl.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: CameraControl.Registry},
      {DynamicSupervisor, name: CameraControl.CameraSupervisor, strategy: :one_for_one},
      {Bandit, plug: CameraControl.HttpStream, port: 11000}
    ]

    opts = [strategy: :one_for_one, name: CameraControl.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
