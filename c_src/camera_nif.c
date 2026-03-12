// camera_nif.c — Minimal NIF for camera AE controls.
//
// The GStreamer pipeline now runs in a separate OS process (gst-launch-1.0)
// managed by GstPipelineRunner.ex. This NIF only provides set_controls()
// for the PID auto-exposure controller (to be used in a future iteration).
//
// Running v4l2src in a separate process provides crash isolation: if mmap
// buffers cause a segfault on USB disconnect, only gst-launch dies, not BEAM.

#include <erl_nif.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    int camera_id;
    double target_intensity;
    int min_exp_time_us;
    int max_exp_time_us;
    int min_gain;
    int max_gain;
    int gain_change_step;
    int dec_gain_exp_us;
    int inc_gain_exp_us;
    ErlNifMutex *lock;
} AEState;

static ErlNifResourceType* ae_state_type = NULL;

static void ae_state_dtor(ErlNifEnv* env, void* obj) {
    (void)env;
    AEState *state = (AEState *)obj;
    if (state->lock) {
        enif_mutex_destroy(state->lock);
        state->lock = NULL;
    }
}

// Placeholder start_camera — returns {:ok, resource} with an AE state only.
// The actual GStreamer pipeline is launched by GstPipelineRunner (Elixir Port).
static ERL_NIF_TERM start_camera(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 8) return enif_make_badarg(env);

    int camera_id;
    if (!enif_get_int(env, argv[0], &camera_id)) {
        return enif_make_badarg(env);
    }

    AEState *state = enif_alloc_resource(ae_state_type, sizeof(AEState));
    memset(state, 0, sizeof(AEState));
    state->camera_id = camera_id;
    state->lock = enif_mutex_create("ae_lock");
    state->target_intensity = 0.3;
    state->max_exp_time_us = 3000;
    state->min_exp_time_us = 100;
    state->max_gain = 300;
    state->min_gain = 64;
    state->gain_change_step = 20;
    state->dec_gain_exp_us = 250;
    state->inc_gain_exp_us = 2950;

    ERL_NIF_TERM resource_term = enif_make_resource(env, state);
    enif_release_resource(state);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), resource_term);
}

static ERL_NIF_TERM set_controls(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 9) return enif_make_badarg(env);

    AEState *state;
    if (!enif_get_resource(env, argv[0], ae_state_type, (void**)&state)) {
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
    // No-op: pipeline cleanup is handled by GstPipelineRunner (kill gst-launch process)
    return enif_make_atom(env, "ok");
}

static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;

    ErlNifResourceFlags flags = (ErlNifResourceFlags)(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
    ae_state_type = enif_open_resource_type(env, NULL, "AEState", ae_state_dtor, flags, NULL);
    if (!ae_state_type) return -1;

    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"nif_start_camera", 8, start_camera, 0},
    {"stop_camera", 1, stop_camera, 0},
    {"set_controls", 9, set_controls, 0}
};

ERL_NIF_INIT(Elixir.CameraControl.Nif, nif_funcs, load, NULL, NULL, NULL)
