defmodule CameraControl.DeviceFinder do
  @moduledoc """
  Finds V4L2 device paths based on USB bus identifiers.
  """

  @rpi4_usb_identifiers [
    "usb-0000:01:00.0-1.1",
    "usb-0000:01:00.0-1.2",
    "usb-0000:01:00.0-1.4"
  ]

  @opcm4_usb_identifiers [
    ["usb-0000:01:00.0-1.3", "usb-0000:01:00.0-1.1"],
    "usb-0000:01:00.0-1.2",
    "usb-xhci-hcd.3.auto-1.3"
  ]

  def get_device_path(camera_id, board_id) do
    identifiers =
      if board_id == "rpi4" do
        @rpi4_usb_identifiers
      else
        @opcm4_usb_identifiers
      end

    if camera_id >= length(identifiers) do
      nil
    else
      target = Enum.at(identifiers, camera_id)
      targets = if is_list(target), do: target, else: [target]

      find_device(targets)
    end
  end

  defp find_device(targets) do
    case System.cmd("v4l2-ctl", ["--list-devices"], stderr_to_stdout: true) do
      {output, _exit_code} ->
        if String.contains?(output, "/dev/video") do
          parse_v4l2_output(output, targets)
        else
          nil
        end
    end
  rescue
    _ -> nil
  end

  defp parse_v4l2_output(output, targets) do
    lines = String.split(output, "\n")

    Enum.reduce_while(lines, false, fn line, matched ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" ->
          {:cont, matched}

        not String.starts_with?(line, "\t") and not String.starts_with?(line, " ") ->
          is_match = Enum.any?(targets, &String.contains?(line, &1))
          {:cont, is_match}

        matched and String.contains?(line, "/dev/video") ->
          path = trimmed

          card_type =
            case System.cmd("v4l2-ctl", ["--all", "--device", path], stderr_to_stdout: true) do
              {info_output, 0} ->
                info_output
                |> String.split("\n")
                |> Enum.find_value("", fn l ->
                  if String.contains?(l, "Card type") do
                    l |> String.split(":", parts: 2) |> List.last() |> String.trim()
                  end
                end)

              _ ->
                ""
            end

          {:halt, {path, card_type}}

        true ->
          {:cont, matched}
      end
    end)
    |> case do
      {path, card_type} when is_binary(path) -> {path, card_type}
      _ -> nil
    end
  end
end
