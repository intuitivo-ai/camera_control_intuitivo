#include <erl_nif.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <ctype.h>

typedef struct {
    int camera_id;
    char camera_path[64];
    char board_id[32];
    char card_type[64];
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
    gint64 last_time_us;
    ErlNifMutex *lock;
} CameraState;

static ErlNifResourceType* camera_state_type = NULL;

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

static int is_usb_camera(const char *card_type) {
    if (strlen(card_type) == 0) return 0;
    char card_lower[64];
    size_t len = strlen(card_type);
    if (len >= sizeof(card_lower)) len = sizeof(card_lower) - 1;
    for (size_t i = 0; i < len; i++) {
        card_lower[i] = tolower((unsigned char)card_type[i]);
    }
    card_lower[len] = '\0';
    return (strstr(card_lower, "usb live camera") != NULL ||
            strstr(card_lower, "gbx usb live") != NULL);
}

static GstFlowReturn on_new_gray_sample(GstAppSink *sink, gpointer user_data) {
    CameraState *state = (CameraState *)user_data;
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_ERROR;

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        double sum = 0;
        for (gsize i = 0; i < map.size; i++) {
            sum += map.data[i];
        }
        double mean_intensity = sum / map.size;

        // g_get_monotonic_time() returns microseconds (gint64)
        gint64 current_time_us = g_get_monotonic_time();

        enif_mutex_lock(state->lock);

        double dt = (current_time_us - state->last_time_us) / 1e6;
        if (dt <= 0) dt = 0.001;
        state->last_time_us = current_time_us;

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

        if (new_exp_time > state->max_exp_time_us) new_exp_time = state->max_exp_time_us;
        if (new_exp_time < state->min_exp_time_us) new_exp_time = state->min_exp_time_us;

        int new_gain = state->current_gain_x;
        if (new_exp_time > state->inc_gain_exp_us) {
            new_gain += state->gain_change_step;
            if (new_gain > state->max_gain) new_gain = state->max_gain;
        } else if (new_exp_time < state->dec_gain_exp_us) {
            new_gain -= state->gain_change_step;
            if (new_gain < state->min_gain) new_gain = state->min_gain;
        }

        state->current_exp_time_us = new_exp_time;
        state->current_gain_x = new_gain;

        enif_mutex_unlock(state->lock);

        {
            ErlNifEnv *msg_env = enif_alloc_env();
            ERL_NIF_TERM msg = enif_make_tuple5(msg_env,
                enif_make_atom(msg_env, "ae_data"),
                enif_make_int(msg_env, state->camera_id),
                enif_make_int(msg_env, new_exp_time),
                enif_make_int(msg_env, new_gain),
                enif_make_double(msg_env, mean_intensity));
            enif_send(NULL, &state->target_pid, msg_env, msg);
            enif_free_env(msg_env);
        }

        gst_buffer_unmap(buffer, &map);
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

static void safe_strncpy(char *dst, const char *src, size_t dst_size) {
    size_t len = strlen(src);
    if (len >= dst_size) len = dst_size - 1;
    memcpy(dst, src, len);
    dst[len] = '\0';
}

static GstBusSyncReply bus_sync_handler(GstBus *bus, GstMessage *msg, gpointer user_data) {
    (void)bus;
    CameraState *state = (CameraState *)user_data;

    if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
        GError *err = NULL;
        gst_message_parse_error(msg, &err, NULL);

        ErlNifEnv *env = enif_alloc_env();
        ERL_NIF_TERM msg_term = enif_make_tuple3(env,
            enif_make_atom(env, "pipeline_error"),
            enif_make_int(env, state->camera_id),
            enif_make_string(env, err ? err->message : "unknown", ERL_NIF_LATIN1));
        enif_send(NULL, &state->target_pid, env, msg_term);
        enif_free_env(env);

        if (err) g_error_free(err);
    }
    return GST_BUS_PASS;
}

static ERL_NIF_TERM start_camera(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 8) return enif_make_badarg(env);

    int camera_id, fw, fh, fps;
    char board_id[32];
    char camera_path[64];
    char card_type[64];
    ErlNifPid target_pid;

    if (!enif_get_int(env, argv[0], &camera_id) ||
        !enif_get_string(env, argv[1], board_id, sizeof(board_id), ERL_NIF_LATIN1) ||
        !enif_get_string(env, argv[2], camera_path, sizeof(camera_path), ERL_NIF_LATIN1) ||
        !enif_get_string(env, argv[3], card_type, sizeof(card_type), ERL_NIF_LATIN1) ||
        !enif_get_int(env, argv[4], &fw) ||
        !enif_get_int(env, argv[5], &fh) ||
        !enif_get_int(env, argv[6], &fps) ||
        !enif_get_local_pid(env, argv[7], &target_pid)) {
        return enif_make_badarg(env);
    }

    CameraState *state = enif_alloc_resource(camera_state_type, sizeof(CameraState));
    memset(state, 0, sizeof(CameraState));

    state->camera_id = camera_id;
    safe_strncpy(state->board_id, board_id, sizeof(state->board_id));
    safe_strncpy(state->camera_path, camera_path, sizeof(state->camera_path));
    safe_strncpy(state->card_type, card_type, sizeof(state->card_type));
    state->target_pid = target_pid;
    state->lock = enif_mutex_create("camera_ae_lock");

    if (is_usb_camera(state->card_type)) {
        state->target_intensity = 0.3;
        state->max_exp_time_us = 3000;
        state->min_exp_time_us = 100;
        state->max_gain = 300;
        state->min_gain = 64;
        state->gain_change_step = 20;
        state->dec_gain_exp_us = 250;
        state->inc_gain_exp_us = 2950;
    } else {
        state->target_intensity = 0.3;
        state->max_exp_time_us = 1100;
        state->min_exp_time_us = 100;
        state->max_gain = 24;
        state->min_gain = 0;
        state->gain_change_step = 1;
        state->dec_gain_exp_us = 350;
        state->inc_gain_exp_us = 950;
    }
    state->current_exp_time_us = 1400;
    state->current_gain_x = 1;
    state->last_time_us = g_get_monotonic_time();

    // io-mode=0 (auto): let GStreamer negotiate the best buffer mode with the driver.
    // Previously io-mode=2 (userptr) was hardcoded, but uvcvideo (USB cameras) doesn't
    // implement userptr — causing silent fallback or intermittent stalls.
    char pipeline_str[2048];
    if (strcmp(board_id, "rpi4") == 0 && !is_usb_camera(state->card_type)) {
        snprintf(pipeline_str, sizeof(pipeline_str),
            "v4l2src device=%s ! image/jpeg,width=%d,height=%d,framerate=%d/1 ! tee name=t "
            "t. ! queue max-size-buffers=600 max-size-bytes=104857600 max-size-time=6000000000 ! gdppay ! queue max-size-buffers=600 max-size-bytes=104857600 max-size-time=6000000000 ! tcpserversink host=127.0.0.1 port=%d "
            "t. ! queue max-size-buffers=2 leaky=downstream ! appsink name=jpeg_sink drop=true max-buffers=2 sync=false "
            "t. ! queue max-size-buffers=2 leaky=downstream ! videorate ! image/jpeg,framerate=4/1 ! jpegdec ! videoconvert ! video/x-raw,format=GRAY8 ! appsink name=gray_sink drop=true max-buffers=1 sync=false",
            camera_path, fw, fh, fps, 5000 + camera_id);
    } else {
        snprintf(pipeline_str, sizeof(pipeline_str),
            "v4l2src device=%s ! image/jpeg,width=%d,height=%d,framerate=%d/1 ! tee name=t "
            "t. ! queue max-size-buffers=200 max-size-bytes=52428800 max-size-time=5000000000 leaky=downstream ! gdppay ! queue max-size-buffers=200 leaky=downstream ! tcpserversink host=127.0.0.1 port=%d sync-method=latest-keyframe recover-policy=keyframe "
            "t. ! queue max-size-buffers=2 leaky=downstream ! appsink name=jpeg_sink drop=true max-buffers=2 sync=false "
            "t. ! queue max-size-buffers=2 leaky=downstream ! videorate ! image/jpeg,framerate=4/1 ! jpegdec ! videoconvert ! video/x-raw,format=GRAY8 ! appsink name=gray_sink drop=true max-buffers=1 sync=false",
            camera_path, fw, fh, fps, 5000 + camera_id);
    }

    GError *error = NULL;
    state->pipeline = gst_parse_launch(pipeline_str, &error);
    if (error) {
        fprintf(stderr, "Failed to parse pipeline: %s\n", error->message);
        g_error_free(error);
        enif_mutex_destroy(state->lock);
        enif_release_resource(state);
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
            enif_make_string(env, "pipeline_parse_error", ERL_NIF_LATIN1));
    }

    GstElement *jpeg_sink = gst_bin_get_by_name(GST_BIN(state->pipeline), "jpeg_sink");
    gst_app_sink_set_emit_signals(GST_APP_SINK(jpeg_sink), TRUE);
    g_signal_connect(jpeg_sink, "new-sample", G_CALLBACK(on_new_jpeg_sample), state);
    gst_object_unref(jpeg_sink);

    GstElement *gray_sink = gst_bin_get_by_name(GST_BIN(state->pipeline), "gray_sink");
    gst_app_sink_set_emit_signals(GST_APP_SINK(gray_sink), TRUE);
    g_signal_connect(gray_sink, "new-sample", G_CALLBACK(on_new_gray_sample), state);
    gst_object_unref(gray_sink);

    GstBus *bus = gst_element_get_bus(state->pipeline);
    gst_bus_set_sync_handler(bus, bus_sync_handler, state, NULL);
    gst_object_unref(bus);

    GstStateChangeReturn ret = gst_element_set_state(state->pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        fprintf(stderr, "Camera %d: pipeline failed to start\n", camera_id);
        gst_element_set_state(state->pipeline, GST_STATE_NULL);
        gst_element_get_state(state->pipeline, NULL, NULL, 5 * GST_SECOND);
        gst_object_unref(state->pipeline);
        state->pipeline = NULL;
        enif_mutex_destroy(state->lock);
        enif_release_resource(state);
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
            enif_make_string(env, "pipeline_start_failed", ERL_NIF_LATIN1));
    }

    GstState actual_state;
    GstStateChangeReturn state_ret = gst_element_get_state(state->pipeline, &actual_state, NULL, 5 * GST_SECOND);
    if (state_ret == GST_STATE_CHANGE_FAILURE || actual_state != GST_STATE_PLAYING) {
        fprintf(stderr, "Camera %d: pipeline did not reach PLAYING (state=%d, ret=%d)\n",
                camera_id, actual_state, state_ret);
        gst_element_set_state(state->pipeline, GST_STATE_NULL);
        gst_element_get_state(state->pipeline, NULL, NULL, 5 * GST_SECOND);
        gst_object_unref(state->pipeline);
        state->pipeline = NULL;
        enif_mutex_destroy(state->lock);
        enif_release_resource(state);
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
            enif_make_string(env, "pipeline_not_playing", ERL_NIF_LATIN1));
    }

    ERL_NIF_TERM resource_term = enif_make_resource(env, state);
    enif_release_resource(state);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), resource_term);
}

static ERL_NIF_TERM set_controls(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 9) return enif_make_badarg(env);

    CameraState *state;
    if (!enif_get_resource(env, argv[0], camera_state_type, (void**)&state)) {
        return enif_make_badarg(env);
    }

    double target_intensity;
    int max_exp, min_exp, max_g, min_g, gain_step, dec_g, inc_g;

    if (!enif_get_double(env, argv[1], &target_intensity) ||
        !enif_get_int(env, argv[2], &max_exp) ||
        !enif_get_int(env, argv[3], &min_exp) ||
        !enif_get_int(env, argv[4], &max_g) ||
        !enif_get_int(env, argv[5], &min_g) ||
        !enif_get_int(env, argv[6], &gain_step) ||
        !enif_get_int(env, argv[7], &dec_g) ||
        !enif_get_int(env, argv[8], &inc_g)) {
        return enif_make_badarg(env);
    }

    enif_mutex_lock(state->lock);
    state->target_intensity = target_intensity;
    state->max_exp_time_us = max_exp;
    state->min_exp_time_us = min_exp;
    state->max_gain = max_g;
    state->min_gain = min_g;
    state->gain_change_step = gain_step;
    state->dec_gain_exp_us = dec_g;
    state->inc_gain_exp_us = inc_g;
    enif_mutex_unlock(state->lock);

    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM stop_camera(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);

    CameraState *state;
    if (!enif_get_resource(env, argv[0], camera_state_type, (void**)&state)) {
        return enif_make_badarg(env);
    }

    if (state->pipeline) {
        gst_element_set_state(state->pipeline, GST_STATE_NULL);
        gst_element_get_state(state->pipeline, NULL, NULL, 5 * GST_SECOND);
        gst_object_unref(state->pipeline);
        state->pipeline = NULL;
    }

    return enif_make_atom(env, "ok");
}

static void camera_state_dtor(ErlNifEnv* env, void* obj) {
    (void)env;
    CameraState *state = (CameraState *)obj;
    if (state->pipeline) {
        gst_element_set_state(state->pipeline, GST_STATE_NULL);
        gst_element_get_state(state->pipeline, NULL, NULL, 3 * GST_SECOND);
        gst_object_unref(state->pipeline);
        state->pipeline = NULL;
    }
    if (state->lock) {
        enif_mutex_destroy(state->lock);
        state->lock = NULL;
    }
}

static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;
    gst_init(NULL, NULL);
    
    ErlNifResourceFlags flags = (ErlNifResourceFlags)(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
    camera_state_type = enif_open_resource_type(env, NULL, "CameraState", camera_state_dtor, flags, NULL);
    if (!camera_state_type) return -1;
    
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"nif_start_camera", 8, start_camera, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"stop_camera", 1, stop_camera, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_controls", 9, set_controls, 0}
};

ERL_NIF_INIT(Elixir.CameraControl.Nif, nif_funcs, load, NULL, NULL, NULL)
