defmodule CameraControl.Nif do
  @moduledoc """
  NIF bindings for GStreamer and V4L2 camera control.
  """
  @on_load :load_nif

  def load_nif do
    nif_file = :code.priv_dir(:camera_control) |> Path.join("camera_nif")
    :erlang.load_nif(to_charlist(nif_file), 0)
  end

  @doc """
  Starts a camera and links it to the target PID.
  Returns `{:ok, resource}` or `{:error, reason}`.
  """
  def start_camera(_id, _board_id, _path, _width, _height, _fps, _target_pid) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Stops the camera and releases resources.
  """
  def stop_camera(_resource) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
