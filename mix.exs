defmodule CameraControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :camera_control,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_env: make_env(),
      deps: deps()
    ]
  end

  # When building as a Nerves dependency (rpi4_dev, opcm4_dev, etc.), ensure
  # the Makefile gets CROSSCOMPILE=1 so it uses the Nerves toolchain.
  defp make_env do
    case to_string(Mix.env()) do
      env when env in ["rpi4_dev", "rpi4_prod", "opcm4_dev", "opcm4_prod"] ->
        %{"CROSSCOMPILE" => "1"}

      _ ->
        %{}
    end
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CameraControl.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_make, "~> 0.7", runtime: false},
      {:bandit, "~> 1.0"}
    ]
  end
end
