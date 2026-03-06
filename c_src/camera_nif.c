#include <erl_nif.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

typedef struct {
    int camera_id;
    char camera_path[64];
    char board_id[32];
    int fd;
    GstElement *pipeline;
    ErlNifPid target_pid;
    
    // Auto Exposure State
    double target_intensity;
    int min_exp_time_us;
    int max_exp_time_us;
    int min_gain;
    int max_gain;
    int gain_change_step;
    int dec_gain_exp_us;
    int inc_gain_exp_us;
    
    double pid_integral;
    double prev_error;
    int current_exp_time_us;
    int current_gain_x;
    gint64 last_time_ns;
} CameraState;

static ErlNifResourceType* camera_state_type = NULL;

static void set_v4l2_ctrl(int fd, int ctrl_id, int value) {
    if (fd < 0) return;
    struct v4l2_control ctrl;
    ctrl.id = ctrl_id;
    ctrl.value = value;
    if (ioctl(fd, VIDIOC_S_CTRL, &ctrl) == -1) {
        // Handle error silently or log
    }
}

static GstFlowReturn on_new_jpeg_sample(GstAppSink *sink, gpointer user_data) {
    CameraState *state = (CameraState *)user_data;
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_ERROR;

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        ErlNifEnv *env = enif_alloc_env();
        ERL_NIF_TERM bin_term;
        unsigned char *bin_data = enif_make_new_binary(env, map.size, &bin_term);
        memcpy(bin_data, map.data, map.size);
        
        ERL_NIF_TERM msg = enif_make_tuple3(env,
            enif_make_atom(env, "jpeg_frame"),
            enif_make_int(env, state->camera_id),
            bin_term
        );
        
        enif_send(NULL, &state->target_pid, env, msg);
        enif_free_env(env);
        gst_buffer_unmap(buffer, &map);
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

static GstFlowReturn on_new_gray_sample(GstAppSink *sink, gpointer user_data) {
    CameraState *state = (CameraState *)user_data;
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_ERROR;

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        // Calculate mean intensity
        double sum = 0;
        for (gsize i = 0; i < map.size; i++) {
            sum += map.data[i];
        }
        double mean_intensity = sum / map.size;
        
        // PID Calculation
        gint64 current_time_ns = g_get_monotonic_time();
        double dt = (current_time_ns - state->last_time_ns) / 1e9;
        if (dt <= 0) dt = 0.001;
        state->last_time_ns = current_time_ns;

        double intensity = 255.0 * state->target_intensity;
        double error = intensity - mean_intensity;

        double Kp = 0.5, Ki = 0.01, Kd = 0.01, output_scale = 0.005;
        double max_integral = 500.0;

        double P = Kp * error;
        
        state->pid_integral += error * dt;
        if (state->pid_integral > max_integral) state->pid_integral = max_integral;
        if (state->pid_integral < -max_integral) state->pid_integral = -max_integral;
        double I = Ki * state->pid_integral;
        
        double derivative_error = (error - state->prev_error) / dt;
        double D = Kd * derivative_error;
        
        double control_output = P + I + D;
        double scaled_output = 1.0 + control_output * output_scale;
        
        int new_exp_time = (int)(state->current_exp_time_us * scaled_output);
        state->prev_error = error;
        
        // Clamp exposure
        if (new_exp_time > state->max_exp_time_us) new_exp_time = state->max_exp_time_us;
        if (new_exp_time < state->min_exp_time_us) new_exp_time = state->min_exp_time_us;
        
        // Update gain
        int new_gain = state->current_gain_x;
        if (new_exp_time > state->inc_gain_exp_us) {
            new_gain += state->gain_change_step;
            if (new_gain > state->max_gain) new_gain = state->max_gain;
        } else if (new_exp_time < state->dec_gain_exp_us) {
            new_gain -= state->gain_change_step;
            if (new_gain < state->min_gain) new_gain = state->min_gain;
        }
        
        // Apply controls via ioctl
        if (new_exp_time != state->current_exp_time_us) {
            state->current_exp_time_us = new_exp_time;
            int exp_to_apply = new_exp_time;
            // USB camera heuristic like python
            if (strstr(state->camera_path, "usb")) {
                exp_to_apply = new_exp_time / 9.5;
            } else {
                exp_to_apply = (new_exp_time / 1000.0) / 0.1;
            }
            
            // Note: V4L2_CID_EXPOSURE_ABSOLUTE = 0x009a0902
            set_v4l2_ctrl(state->fd, V4L2_CID_EXPOSURE_ABSOLUTE, exp_to_apply);
        }
        
        if (new_gain != state->current_gain_x) {
            state->current_gain_x = new_gain;
            set_v4l2_ctrl(state->fd, V4L2_CID_GAIN, new_gain);
        }

        gst_buffer_unmap(buffer, &map);
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

static ERL_NIF_TERM start_camera(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 7) return enif_make_badarg(env);

    int camera_id, fw, fh, fps;
    char board_id[32];
    char camera_path[64];
    ErlNifPid target_pid;

    if (!enif_get_int(env, argv[0], &camera_id) ||
        !enif_get_string(env, argv[1], board_id, sizeof(board_id), ERL_NIF_LATIN1) ||
        !enif_get_string(env, argv[2], camera_path, sizeof(camera_path), ERL_NIF_LATIN1) ||
        !enif_get_int(env, argv[3], &fw) ||
        !enif_get_int(env, argv[4], &fh) ||
        !enif_get_int(env, argv[5], &fps) ||
        !enif_get_local_pid(env, argv[6], &target_pid)) {
        return enif_make_badarg(env);
    }

    CameraState *state = enif_alloc_resource(camera_state_type, sizeof(CameraState));
    memset(state, 0, sizeof(CameraState));
    
    state->camera_id = camera_id;
    strncpy(state->board_id, board_id, sizeof(state->board_id));
    strncpy(state->camera_path, camera_path, sizeof(state->camera_path));
    state->target_pid = target_pid;
    
    // Default AE settings
    state->target_intensity = 0.3;
    state->max_exp_time_us = 1100;
    state->min_exp_time_us = 100;
    state->max_gain = 24;
    state->min_gain = 0;
    state->gain_change_step = 1;
    state->dec_gain_exp_us = 350;
    state->inc_gain_exp_us = 950;
    state->current_exp_time_us = 1400;
    state->current_gain_x = 1;
    state->last_time_ns = g_get_monotonic_time();
    
    // Open FD for V4L2
    state->fd = open(state->camera_path, O_RDWR);
    if (state->fd >= 0) {
        // Set auto exposure to manual
        set_v4l2_ctrl(state->fd, V4L2_CID_EXPOSURE_AUTO, 1);
        // Set power line frequency
        set_v4l2_ctrl(state->fd, V4L2_CID_POWER_LINE_FREQUENCY, 2);
        // Set focus auto off
        set_v4l2_ctrl(state->fd, V4L2_CID_FOCUS_AUTO, 0);
    }
    
    char pipeline_str[1024];
    snprintf(pipeline_str, sizeof(pipeline_str),
        "v4l2src device=%s io-mode=2 ! image/jpeg,width=%d,height=%d,framerate=%d/1 ! tee name=t "
        "t. ! queue ! appsink name=jpeg_sink drop=true max-buffers=2 "
        "t. ! queue ! videorate ! video/x-raw,framerate=4/1 ! jpegdec ! videoconvert ! video/x-raw,format=GRAY8 ! appsink name=gray_sink drop=true max-buffers=1",
        camera_path, fw, fh, fps);
        
    GError *error = NULL;
    state->pipeline = gst_parse_launch(pipeline_str, &error);
    if (error) {
        g_printerr("Failed to parse pipeline: %s\n", error->message);
        g_error_free(error);
        enif_release_resource(state);
        return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_string(env, "pipeline_parse_error", ERL_NIF_LATIN1));
    }
    
    GstElement *jpeg_sink = gst_bin_get_by_name(GST_BIN(state->pipeline), "jpeg_sink");
    gst_app_sink_set_emit_signals(GST_APP_SINK(jpeg_sink), TRUE);
    g_signal_connect(jpeg_sink, "new-sample", G_CALLBACK(on_new_jpeg_sample), state);
    
    GstElement *gray_sink = gst_bin_get_by_name(GST_BIN(state->pipeline), "gray_sink");
    gst_app_sink_set_emit_signals(GST_APP_SINK(gray_sink), TRUE);
    g_signal_connect(gray_sink, "new-sample", G_CALLBACK(on_new_gray_sample), state);
    
    gst_element_set_state(state->pipeline, GST_STATE_PLAYING);
    
    ERL_NIF_TERM resource_term = enif_make_resource(env, state);
    enif_release_resource(state);
    
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), resource_term);
}

static ERL_NIF_TERM stop_camera(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);
    
    CameraState *state;
    if (!enif_get_resource(env, argv[0], camera_state_type, (void**)&state)) {
        return enif_make_badarg(env);
    }
    
    if (state->pipeline) {
        gst_element_send_event(state->pipeline, gst_event_new_eos());
        gst_element_set_state(state->pipeline, GST_STATE_NULL);
        gst_object_unref(state->pipeline);
        state->pipeline = NULL;
    }
    if (state->fd >= 0) {
        close(state->fd);
        state->fd = -1;
    }
    
    return enif_make_atom(env, "ok");
}

static void camera_state_dtor(ErlNifEnv* env, void* obj) {
    CameraState *state = (CameraState *)obj;
    if (state->pipeline) {
        gst_element_set_state(state->pipeline, GST_STATE_NULL);
        gst_object_unref(state->pipeline);
    }
    if (state->fd >= 0) {
        close(state->fd);
    }
}

static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    gst_init(NULL, NULL);
    
    ErlNifResourceFlags flags = (ErlNifResourceFlags)(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
    camera_state_type = enif_open_resource_type(env, NULL, "CameraState", camera_state_dtor, flags, NULL);
    if (!camera_state_type) return -1;
    
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"start_camera", 7, start_camera, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"stop_camera", 1, stop_camera, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(Elixir.CameraControl.Nif, nif_funcs, load, NULL, NULL, NULL)
