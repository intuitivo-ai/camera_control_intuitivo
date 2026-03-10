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

  String arguments are converted to charlists for C enif_get_string compatibility.
  """
  def start_camera(id, board_id, path, card_type, width, height, fps, target_pid) do
    nif_start_camera(
      id,
      to_charlist(board_id),
      to_charlist(path),
      to_charlist(card_type),
      width,
      height,
      fps,
      target_pid
    )
  end

  @doc false
  def nif_start_camera(_id, _board_id, _path, _card_type, _width, _height, _fps, _target_pid) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Stops the camera and releases resources.
  """
  def stop_camera(_resource) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Updates auto-exposure parameters at runtime.
  """
  def set_controls(_resource, _target_intensity, _max_exp, _min_exp, _max_gain, _min_gain, _gain_step, _dec_gain, _inc_gain) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
