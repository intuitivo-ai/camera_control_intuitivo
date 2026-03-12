defmodule CameraControl.PidTracker do
  @moduledoc """
  Tracks OS PIDs of gst-launch-1.0 processes per camera in an ETS table.

  Ensures orphaned gst-launch processes are killed even if the owning GenServer
  dies without running terminate/2 (e.g., brutal_kill from supervisor).

  Usage:
    - Call kill_all/2 before starting a new pipeline to clean up any leftovers
    - Call register/3 after Port.open to track the new OS PID
    - Call unregister/2 in terminate to remove the entry
  """

  @table :gst_pid_tracker

  @doc "Register an OS PID for a camera+type pair. Type is :pipeline or :ae_reader."
  def register(camera_id, type, os_pid) do
    :ets.insert(@table, {camera_id, type, os_pid})
  rescue
    _ -> :ok
  end

  @doc "Remove all entries for a camera+type pair."
  def unregister(camera_id, type) do
    :ets.match_delete(@table, {camera_id, type, :_})
  rescue
    _ -> :ok
  end

  @doc """
  Kill all tracked gst-launch OS PIDs for a camera+type and remove them from the table.
  Sends SIGINT first (triggers EOS in gst-launch -e), falls back to SIGKILL after 2s
  if the process is still alive.
  """
  def kill_all(camera_id, type) do
    pids =
      :ets.match(@table, {camera_id, type, :"$1"})
      |> List.flatten()

    Enum.each(pids, fn os_pid ->
      # SIGINT triggers clean EOS shutdown in gst-launch-1.0 -e
      System.cmd("kill", ["-SIGINT", "#{os_pid}"], stderr_to_stdout: true)
    end)

    # Give processes a moment to exit cleanly, then force-kill survivors
    if pids != [] do
      Process.sleep(500)

      Enum.each(pids, fn os_pid ->
        case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
          {_, 0} ->
            # Still alive, force kill
            System.cmd("kill", ["-SIGKILL", "#{os_pid}"], stderr_to_stdout: true)
          _ ->
            :ok
        end
      end)
    end

    unregister(camera_id, type)
  rescue
    _ -> :ok
  end
end
