defmodule CameraControl.V4L2 do
  @moduledoc """
  Applies V4L2 controls via v4l2-ctl, using the correct control names
  per board type (rpi4 vs opcm4) as the original Python script did.
  """
  require Logger

  @usb_camera_identifiers ["usb live camera", "gbx usb live", "arducam"]

  def init_controls(path, board_id, card_type) do
    supported = list_controls(path)

    set_ctrl_if_supported(path, supported, auto_exposure_name(board_id), 1)
    set_ctrl_if_supported(path, supported, "power_line_frequency", 2)
    set_focus_auto(path, board_id, card_type, supported)

    if usb_camera?(card_type) do
      set_defaults_usb(path, board_id)
    end
  end

  def apply_exposure(path, board_id, card_type, exp_time_us) do
    ctrl_name = exposure_name(board_id)

    value =
      if usb_camera?(card_type) do
        trunc(exp_time_us / 9.5)
      else
        trunc(exp_time_us / 1000 / 0.1)
      end

    set_ctrl(path, ctrl_name, value)
  end

  def apply_gain(path, _board_id, gain) do
    set_ctrl(path, "gain", gain)
  end

  defp list_controls(path) do
    case System.cmd("v4l2-ctl", ["--device", path, "--list-ctrls-menus"], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, _} -> output
    end
  rescue
    _ -> ""
  end

  defp set_ctrl_if_supported(path, supported, name, value) do
    if String.contains?(supported, name) do
      set_ctrl(path, name, value)
    else
      Logger.debug("V4L2: control #{name} not supported on #{path}, skipping")
    end
  end

  defp set_ctrl(path, name, value) do
    System.cmd("v4l2-ctl", [
      "--device", path,
      "--set-ctrl=#{name}=#{value}"
    ], stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  defp set_focus_auto(path, "rpi4", card_type, supported) do
    if usb_camera?(card_type) do
      set_ctrl_if_supported(path, supported, "focus_automatic_continuous", 0)
    end
  end

  defp set_focus_auto(path, _board_id, _card_type, supported) do
    set_ctrl_if_supported(path, supported, "focus_auto", 0)
  end

  defp auto_exposure_name("opcm4"), do: "exposure_auto"
  defp auto_exposure_name(_), do: "auto_exposure"

  defp exposure_name("opcm4"), do: "exposure_absolute"
  defp exposure_name(_), do: "exposure_time_absolute"

  defp usb_camera?(card_type) when is_binary(card_type) do
    lower = String.downcase(card_type)
    Enum.any?(@usb_camera_identifiers, &String.contains?(lower, &1))
  end

  defp usb_camera?(_), do: false

  defp set_defaults_usb(_path, _board_id), do: :ok
end
