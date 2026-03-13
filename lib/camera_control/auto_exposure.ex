defmodule CameraControl.AutoExposure do
  @moduledoc """
  PID-based auto-exposure controller per camera.

  Receives grayscale frames from AeFrameReader, calculates mean intensity,
  and adjusts exposure/gain via V4L2.

  Mirrors the Python AutoCameraSettings PID controller:
    - Kp=0.5, Ki=0.01, Kd=0.01, output_scale=0.005
    - Adaptive gain: increase when exposure > inc_gain_exp_us,
      decrease when exposure < dec_gain_exp_us
  """
  use GenServer
  require Logger

  @enforce_keys [:camera_id]
  defstruct [
    :camera_id, :device_path, :board_id, :card_type,
    :ae_reader_pid,
    # AE parameters (set via set_controls)
    target_intensity: 0.3,
    max_exp_us: 3000,
    min_exp_us: 100,
    max_gain: 300,
    min_gain: 64,
    gain_change_step: 20,
    dec_gain_exp_us: 250,
    inc_gain_exp_us: 2950,
    # PID state
    current_exp_us: 100,
    current_gain: 64,
    pid_integral: 0.0,
    prev_error: 0.0,
    max_integral: 500.0,
    last_time: nil,
    mean_intensity: 0.0,
    # Avoid redundant v4l2-ctl calls
    last_applied_exp: 0,
    last_applied_gain: -1,
    # Recording callback
    camera_pid: nil
  ]

  # PID tuning (same as Python)
  @kp 0.5
  @ki 0.01
  @kd 0.01
  @output_scale 0.005

  def start_link(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    name = {:via, Registry, {CameraControl.Registry, "auto_exposure_#{camera_id}"}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def stop(camera_id) do
    case Registry.lookup(CameraControl.Registry, "auto_exposure_#{camera_id}") do
      [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  def update_controls(camera_id, params) do
    case Registry.lookup(CameraControl.Registry, "auto_exposure_#{camera_id}") do
      [{pid, _}] -> GenServer.cast(pid, {:update_controls, params})
      _ -> :ok
    end
  end

  def get_state(camera_id) do
    case Registry.lookup(CameraControl.Registry, "auto_exposure_#{camera_id}") do
      [{pid, _}] -> GenServer.call(pid, :get_state)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    device_path = Keyword.fetch!(opts, :device_path)
    board_id = Keyword.get(opts, :board_id, "rpi4")
    card_type = Keyword.get(opts, :card_type, "")
    camera_pid = Keyword.get(opts, :camera_pid)

    # Start the frame reader
    reader_opts = [camera_id: camera_id, target_pid: self()]
    case CameraControl.AeFrameReader.start_link(reader_opts) do
      {:ok, reader_pid} ->
        Process.monitor(reader_pid)

        Logger.info("AutoExposure camera #{camera_id}: started PID controller")

        {:ok, %__MODULE__{
          camera_id: camera_id,
          device_path: device_path,
          board_id: board_id,
          card_type: card_type,
          ae_reader_pid: reader_pid,
          camera_pid: camera_pid,
          current_exp_us: 100,
          current_gain: 64,
          last_time: System.monotonic_time(:millisecond)
        }}

      {:error, reason} ->
        Logger.error("AutoExposure camera #{camera_id}: failed to start frame reader: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:update_controls, params}, state) do
    state = %{state |
      target_intensity: Map.get(params, :target_intensity, state.target_intensity),
      max_exp_us: Map.get(params, :max_exp_us, state.max_exp_us),
      min_exp_us: Map.get(params, :min_exp_us, state.min_exp_us),
      max_gain: Map.get(params, :max_gain, state.max_gain),
      min_gain: Map.get(params, :min_gain, state.min_gain),
      gain_change_step: Map.get(params, :gain_change_step, state.gain_change_step),
      dec_gain_exp_us: Map.get(params, :dec_gain_exp_us, state.dec_gain_exp_us),
      inc_gain_exp_us: Map.get(params, :inc_gain_exp_us, state.inc_gain_exp_us)
    }

    Logger.info("AutoExposure camera #{state.camera_id}: controls updated (target=#{state.target_intensity})")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    info = %{
      current_exp_us: state.current_exp_us,
      current_gain: state.current_gain,
      mean_intensity: state.mean_intensity
    }
    {:reply, info, state}
  end

  @impl true
  def handle_info({:ae_frame, camera_id, frame_data}, %{camera_id: camera_id} = state) do
    state = process_frame(frame_data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{ae_reader_pid: pid} = state) do
    Logger.warning("AutoExposure camera #{state.camera_id}: frame reader died: #{inspect(reason)}")
    {:stop, {:reader_down, reason}, %{state | ae_reader_pid: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.ae_reader_pid do
      CameraControl.AeFrameReader.stop(state.camera_id)
    end
  end

  # -- PID Controller --

  defp process_frame(frame_data, state) do
    now = System.monotonic_time(:millisecond)
    dt = max((now - state.last_time) / 1000.0, 0.001)

    # Mean intensity of grayscale frame (0-255)
    mean_intensity = compute_mean_intensity(frame_data)

    # Target in 0-255 scale
    target = 255.0 * state.target_intensity
    error = target - mean_intensity

    # PID terms
    p = @kp * error

    integral = state.pid_integral + error * dt
    integral = clamp(integral, -state.max_integral, state.max_integral)
    i = @ki * integral

    derivative = (error - state.prev_error) / dt
    d = @kd * derivative

    # Control output
    control_output = p + i + d
    scaled_output = 1.0 + control_output * @output_scale

    new_exp_us = trunc(state.current_exp_us * scaled_output)
    new_exp_us = clamp(new_exp_us, state.min_exp_us, state.max_exp_us)

    # Adaptive gain
    new_gain = compute_gain(new_exp_us, state)

    # Apply to V4L2 only if changed
    state = apply_if_changed(new_exp_us, new_gain, state)

    # Notify camera process for recording data
    if state.camera_pid do
      send(state.camera_pid, {:ae_update, state.camera_id, new_exp_us, new_gain, mean_intensity})
    end

    %{state |
      current_exp_us: new_exp_us,
      current_gain: new_gain,
      pid_integral: integral,
      prev_error: error,
      last_time: now,
      mean_intensity: mean_intensity
    }
  end

  defp compute_mean_intensity(<<>>), do: 0.0

  defp compute_mean_intensity(frame_data) do
    size = byte_size(frame_data)
    sum = :erlang.binary_to_list(frame_data) |> :lists.sum()
    sum / size
  end

  defp compute_gain(new_exp_us, state) do
    cond do
      new_exp_us > state.inc_gain_exp_us ->
        min(state.current_gain + state.gain_change_step, state.max_gain)
      new_exp_us < state.dec_gain_exp_us ->
        max(state.current_gain - state.gain_change_step, state.min_gain)
      true ->
        state.current_gain
    end
  end

  defp apply_if_changed(exp_us, gain, state) do
    state =
      if exp_us != state.last_applied_exp do
        CameraControl.V4L2.apply_exposure(state.device_path, state.board_id, state.card_type, exp_us)
        %{state | last_applied_exp: exp_us}
      else
        state
      end

    if gain != state.last_applied_gain do
      CameraControl.V4L2.apply_gain(state.device_path, state.board_id, gain)
      %{state | last_applied_gain: gain}
    else
      state
    end
  end

  defp clamp(val, min_val, max_val) when is_number(val) do
    val |> max(min_val) |> min(max_val)
  end
end
