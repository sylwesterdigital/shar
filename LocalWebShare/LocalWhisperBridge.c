#include <whisper/whisper.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    struct whisper_context *ctx;
} shar_whisper_handle;

static void append_text(char **buffer, size_t *length, size_t *capacity, const char *text) {
    if (!text) return;
    size_t add = strlen(text);
    if (*length + add + 1 > *capacity) {
        size_t next = *capacity ? *capacity : 4096;
        while (next < *length + add + 1) next *= 2;
        char *grown = (char *)realloc(*buffer, next);
        if (!grown) return;
        *buffer = grown;
        *capacity = next;
    }
    memcpy(*buffer + *length, text, add);
    *length += add;
    (*buffer)[*length] = '\0';
}

static char *clean_segment_text(const char *text) {
    if (!text) return strdup("");
    size_t n = strlen(text);
    char *out = (char *)malloc(n + 1);
    if (!out) return NULL;
    size_t j = 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)text[i];
        if (c == '\t' || c == '\r' || c == '\n') c = ' ';
        out[j++] = (char)c;
    }
    out[j] = '\0';
    return out;
}

void *shar_whisper_create(const char *model_path) {
    if (!model_path || !*model_path) return NULL;
    struct whisper_context_params cparams = whisper_context_default_params();
    struct whisper_context *ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) return NULL;
    shar_whisper_handle *handle = (shar_whisper_handle *)calloc(1, sizeof(shar_whisper_handle));
    if (!handle) {
        whisper_free(ctx);
        return NULL;
    }
    handle->ctx = ctx;
    return handle;
}

void shar_whisper_destroy(void *opaque) {
    shar_whisper_handle *handle = (shar_whisper_handle *)opaque;
    if (!handle) return;
    if (handle->ctx) whisper_free(handle->ctx);
    free(handle);
}

// Returns UTF-8 TSV rows: start_ms<TAB>end_ms<TAB>text<NEWLINE>.
// The caller owns the returned buffer and must free it with shar_whisper_free_text().
char *shar_whisper_transcribe(void *opaque, const float *samples, int sample_count) {
    shar_whisper_handle *handle = (shar_whisper_handle *)opaque;
    if (!handle || !handle->ctx || !samples || sample_count <= 0) return NULL;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.no_context = true;
    params.single_segment = false;
    params.token_timestamps = true;
    params.temperature_inc = -1.0f;
    params.n_threads = 4;
    params.language = "auto";

    if (whisper_full(handle->ctx, params, samples, sample_count) != 0) return NULL;

    char *output = NULL;
    size_t length = 0, capacity = 0;
    const int count = whisper_full_n_segments(handle->ctx);
    for (int i = 0; i < count; ++i) {
        const int64_t start_ms = whisper_full_get_segment_t0(handle->ctx, i) * 10;
        const int64_t end_ms = whisper_full_get_segment_t1(handle->ctx, i) * 10;
        char *clean = clean_segment_text(whisper_full_get_segment_text(handle->ctx, i));
        if (!clean) continue;
        char prefix[96];
        snprintf(prefix, sizeof(prefix), "%lld\t%lld\t", (long long)start_ms, (long long)end_ms);
        append_text(&output, &length, &capacity, prefix);
        append_text(&output, &length, &capacity, clean);
        append_text(&output, &length, &capacity, "\n");
        free(clean);
    }
    if (!output) output = strdup("");
    return output;
}

void shar_whisper_free_text(char *text) {
    free(text);
}
