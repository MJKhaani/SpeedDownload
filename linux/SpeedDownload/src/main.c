#define _POSIX_C_SOURCE 200809L

#include <gtk/gtk.h>
#include <gio/gunixsocketaddress.h>
#include <json-glib/json-glib.h>

#include <stdint.h>
#include <string.h>

#define MAX_FRAME_SIZE (1024u * 1024u)
#define REFRESH_INTERVAL_SECONDS 2

typedef struct {
    gchar *job_id;
    gchar *url;
    gchar *name;
    gchar *destination;
    gchar *state;
    gchar *revision;
    gchar *error_message;
    gchar *completed_bytes;
    gchar *total_bytes;
    gchar *requested_control;
    gint priority;
} DownloadJob;

typedef struct {
    GtkApplication *application;
    GtkWindow *window;
    GtkListBox *job_list;
    GtkLabel *connection_status;
    GtkLabel *message_status;
    gboolean refresh_in_flight;
} AppState;

typedef struct {
    gchar *method;
    JsonNode *params;
    gboolean refresh;
} RpcTask;

static void on_job_action(GtkButton *button, gpointer user_data);
static gboolean refresh_jobs(AppState *app);
static const gchar *json_string(JsonObject *object, const gchar *key);

static void download_job_free(gpointer data) {
    DownloadJob *job = data;
    if (job == NULL) return;
    g_free(job->job_id);
    g_free(job->url);
    g_free(job->name);
    g_free(job->destination);
    g_free(job->state);
    g_free(job->revision);
    g_free(job->error_message);
    g_free(job->completed_bytes);
    g_free(job->total_bytes);
    g_free(job->requested_control);
    g_free(job);
}

static void rpc_task_free(gpointer data) {
    RpcTask *task = data;
    if (task == NULL) return;
    g_free(task->method);
    if (task->params != NULL) json_node_unref(task->params);
    g_free(task);
}

static gchar *socket_path(void) {
    const gchar *runtime = g_getenv("XDG_RUNTIME_DIR");
    if (runtime == NULL || runtime[0] != '/') return NULL;
    return g_build_filename(runtime, "speed-download", "engine.sock", NULL);
}

static gboolean write_all(GOutputStream *stream, const guint8 *data, gsize length, GCancellable *cancellable, GError **error) {
    gsize written = 0;
    if (!g_output_stream_write_all(stream, data, length, &written, cancellable, error)) return FALSE;
    if (written != length) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not write the complete IPC frame.");
        return FALSE;
    }
    return TRUE;
}

static gboolean read_all(GInputStream *stream, guint8 *data, gsize length, GCancellable *cancellable, GError **error) {
    gsize received = 0;
    if (!g_input_stream_read_all(stream, data, length, &received, cancellable, error)) return FALSE;
    if (received != length) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_CONNECTION_CLOSED, "Engine closed the IPC connection.");
        return FALSE;
    }
    return TRUE;
}

static JsonNode *receive_response(GInputStream *input, const gchar *expected_id, GCancellable *cancellable, GError **error) {
    guint32 prefix = 0;
    if (!read_all(input, (guint8 *)&prefix, sizeof(prefix), cancellable, error)) return NULL;
    guint32 length = GUINT32_FROM_LE(prefix);
    if (length == 0 || length > MAX_FRAME_SIZE) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Engine sent an invalid IPC frame length.");
        return NULL;
    }

    gchar *payload = g_malloc(length + 1);
    if (!read_all(input, (guint8 *)payload, length, cancellable, error)) {
        g_free(payload);
        return NULL;
    }
    payload[length] = '\0';

    JsonParser *parser = json_parser_new();
    if (!json_parser_load_from_data(parser, payload, (gssize)length, error)) {
        g_object_unref(parser);
        g_free(payload);
        return NULL;
    }
    g_free(payload);

    JsonNode *root = json_parser_steal_root(parser);
    g_object_unref(parser);
    if (root == NULL || !JSON_NODE_HOLDS_OBJECT(root)) {
        if (root != NULL) json_node_unref(root);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Engine sent an invalid JSON-RPC response.");
        return NULL;
    }
    JsonObject *object = json_node_get_object(root);
    const gchar *response_id = json_string(object, "id");
    if (response_id == NULL || g_strcmp0(response_id, expected_id) != 0) {
        json_node_unref(root);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Engine response id did not match the request.");
        return NULL;
    }
    if (json_object_has_member(object, "error")) {
        JsonObject *remote_error = json_object_get_object_member(object, "error");
        const gchar *message = json_string(remote_error, "message");
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s", message);
        json_node_unref(root);
        return NULL;
    }
    JsonNode *result = json_object_get_member(object, "result");
    if (result == NULL) {
        json_node_unref(root);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Engine response has no result.");
        return NULL;
    }
    JsonNode *copy = json_node_copy(result);
    json_node_unref(root);
    return copy;
}

static JsonNode *send_request(GOutputStream *output, GInputStream *input, const gchar *method, JsonNode *params, GCancellable *cancellable, GError **error) {
    gchar *request_id = g_uuid_string_random();
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "jsonrpc");
    json_builder_add_string_value(builder, "2.0");
    json_builder_set_member_name(builder, "id");
    json_builder_add_string_value(builder, request_id);
    json_builder_set_member_name(builder, "method");
    json_builder_add_string_value(builder, method);
    json_builder_set_member_name(builder, "params");
    if (params != NULL) json_builder_add_value(builder, json_node_copy(params));
    else {
        json_builder_begin_object(builder);
        json_builder_end_object(builder);
    }
    json_builder_end_object(builder);

    JsonGenerator *generator = json_generator_new();
    JsonNode *request = json_builder_get_root(builder);
    json_generator_set_root(generator, request);
    gsize length = 0;
    gchar *payload = json_generator_to_data(generator, &length);
    json_node_unref(request);
    g_object_unref(generator);
    g_object_unref(builder);

    if (length == 0 || length > MAX_FRAME_SIZE) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_MESSAGE_TOO_LARGE, "IPC request exceeds the frame limit.");
        g_free(payload);
        g_free(request_id);
        return NULL;
    }
    guint32 prefix = GUINT32_TO_LE((guint32)length);
    gboolean sent = write_all(output, (const guint8 *)&prefix, sizeof(prefix), cancellable, error) &&
                    write_all(output, (const guint8 *)payload, length, cancellable, error);
    g_free(payload);
    if (!sent) {
        g_free(request_id);
        return NULL;
    }
    JsonNode *result = receive_response(input, request_id, cancellable, error);
    g_free(request_id);
    return result;
}

static JsonNode *rpc_call(const gchar *method, JsonNode *params, GCancellable *cancellable, GError **error) {
    gchar *path = socket_path();
    if (path == NULL) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "XDG_RUNTIME_DIR is not set to an absolute path.");
        return NULL;
    }
    GSocketClient *client = g_socket_client_new();
    GSocketAddress *address = g_unix_socket_address_new(path);
    GSocketConnection *connection = g_socket_client_connect(client, G_SOCKET_CONNECTABLE(address), cancellable, error);
    g_object_unref(address);
    g_object_unref(client);
    g_free(path);
    if (connection == NULL) return NULL;

    GInputStream *input = g_io_stream_get_input_stream(G_IO_STREAM(connection));
    GOutputStream *output = g_io_stream_get_output_stream(G_IO_STREAM(connection));
    JsonBuilder *hello_params = json_builder_new();
    json_builder_begin_object(hello_params);
    json_builder_set_member_name(hello_params, "protocol");
    json_builder_begin_object(hello_params);
    json_builder_set_member_name(hello_params, "major"); json_builder_add_int_value(hello_params, 1);
    json_builder_set_member_name(hello_params, "minor"); json_builder_add_int_value(hello_params, 0);
    json_builder_end_object(hello_params);
    json_builder_set_member_name(hello_params, "client");
    json_builder_begin_object(hello_params);
    json_builder_set_member_name(hello_params, "kind"); json_builder_add_string_value(hello_params, "linux-gtk");
    json_builder_set_member_name(hello_params, "version"); json_builder_add_string_value(hello_params, "0.1.0");
    json_builder_end_object(hello_params);
    json_builder_set_member_name(hello_params, "features");
    json_builder_begin_array(hello_params); json_builder_end_array(hello_params);
    json_builder_end_object(hello_params);
    JsonNode *hello_node = json_builder_get_root(hello_params);
    g_object_unref(hello_params);
    JsonNode *hello_result = send_request(output, input, "engine.hello", hello_node, cancellable, error);
    json_node_unref(hello_node);
    if (hello_result == NULL) {
        g_object_unref(connection);
        return NULL;
    }
    json_node_unref(hello_result);

    JsonNode *result = send_request(output, input, method, params, cancellable, error);
    g_io_stream_close(G_IO_STREAM(connection), NULL, NULL);
    g_object_unref(connection);
    return result;
}

static const gchar *json_string(JsonObject *object, const gchar *key) {
    if (object == NULL || !json_object_has_member(object, key)) return NULL;
    JsonNode *node = json_object_get_member(object, key);
    return JSON_NODE_HOLDS_VALUE(node) && json_node_get_value_type(node) == G_TYPE_STRING ? json_node_get_string(node) : NULL;
}

static gchar *json_string_copy(JsonObject *object, const gchar *key) {
    const gchar *value = json_string(object, key);
    return value != NULL ? g_strdup(value) : NULL;
}

static guint64 parse_u64(const gchar *value) {
    if (value == NULL || value[0] == '-') return 0;
    gchar *end = NULL;
    guint64 parsed = g_ascii_strtoull(value, &end, 10);
    return end != value && end != NULL && *end == '\0' ? parsed : 0;
}

static DownloadJob *parse_job(JsonNode *node) {
    if (node == NULL || !JSON_NODE_HOLDS_OBJECT(node)) return NULL;
    JsonObject *object = json_node_get_object(node);
    DownloadJob *job = g_new0(DownloadJob, 1);
    job->job_id = json_string_copy(object, "job_id");
    job->url = json_string_copy(object, "url");
    job->name = json_string_copy(object, "name");
    job->destination = json_string_copy(object, "destination");
    job->state = json_string_copy(object, "state");
    job->revision = json_string_copy(object, "revision");
    job->error_message = json_string_copy(object, "error_message");
    job->completed_bytes = json_string_copy(object, "completed_bytes");
    job->total_bytes = json_string_copy(object, "total_bytes");
    job->requested_control = json_string_copy(object, "requested_control");
    if (json_object_has_member(object, "priority")) job->priority = (gint)json_object_get_int_member(object, "priority");
    if (job->job_id == NULL || job->url == NULL || job->destination == NULL || job->state == NULL || job->revision == NULL) {
        download_job_free(job);
        return NULL;
    }
    return job;
}

static GPtrArray *parse_jobs(JsonNode *result, GError **error) {
    if (result == NULL || !JSON_NODE_HOLDS_OBJECT(result)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Engine returned an invalid job list.");
        return NULL;
    }
    JsonObject *object = json_node_get_object(result);
    JsonArray *array = json_object_get_array_member(object, "jobs");
    if (array == NULL) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Engine response has no jobs array.");
        return NULL;
    }
    GPtrArray *jobs = g_ptr_array_new_with_free_func(download_job_free);
    for (guint i = 0; i < json_array_get_length(array); i++) {
        DownloadJob *job = parse_job(json_array_get_element(array, i));
        if (job == NULL) {
            g_ptr_array_unref(jobs);
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Engine returned a malformed job.");
            return NULL;
        }
        g_ptr_array_add(jobs, job);
    }
    return jobs;
}

static void set_message(AppState *app, const gchar *message, gboolean is_error) {
    gtk_label_set_text(app->message_status, message != NULL ? message : "");
    gtk_widget_set_visible(GTK_WIDGET(app->message_status), message != NULL && message[0] != '\0');
    gtk_widget_remove_css_class(GTK_WIDGET(app->message_status), "error");
    if (is_error) gtk_widget_add_css_class(GTK_WIDGET(app->message_status), "error");
}

static void add_action_button(GtkWidget *box, AppState *app, DownloadJob *job, const gchar *label, const gchar *action) {
    GtkWidget *button = gtk_button_new_with_label(label);
    g_object_set_data_full(G_OBJECT(button), "job-id", g_strdup(job->job_id), g_free);
    g_object_set_data_full(G_OBJECT(button), "revision", g_strdup(job->revision), g_free);
    g_object_set_data_full(G_OBJECT(button), "action", g_strdup(action), g_free);
    g_signal_connect(button, "clicked", G_CALLBACK(on_job_action), app);
    gtk_box_append(GTK_BOX(box), button);
}

static GtkWidget *create_job_row(AppState *app, DownloadJob *job) {
    GtkWidget *row = gtk_list_box_row_new();
    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(outer, 12);
    gtk_widget_set_margin_bottom(outer, 12);
    gtk_widget_set_margin_start(outer, 14);
    gtk_widget_set_margin_end(outer, 14);

    const gchar *title = job->name != NULL && job->name[0] != '\0' ? job->name : job->url;
    GtkWidget *heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *title_label = gtk_label_new(title);
    gtk_label_set_xalign(GTK_LABEL(title_label), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(title_label), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(title_label, TRUE);
    gtk_widget_add_css_class(title_label, "title-4");
    GtkWidget *state_label = gtk_label_new(job->state);
    gtk_widget_add_css_class(state_label, "dim-label");
    gtk_box_append(GTK_BOX(heading), title_label);
    gtk_box_append(GTK_BOX(heading), state_label);
    gtk_box_append(GTK_BOX(outer), heading);

    GtkWidget *url_label = gtk_label_new(job->url);
    gtk_label_set_xalign(GTK_LABEL(url_label), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(url_label), PANGO_ELLIPSIZE_MIDDLE);
    gtk_widget_add_css_class(url_label, "dim-label");
    gtk_box_append(GTK_BOX(outer), url_label);

    guint64 completed = parse_u64(job->completed_bytes);
    guint64 total = parse_u64(job->total_bytes);
    if (g_strcmp0(job->state, "downloading") == 0 && total > 0) {
        GtkWidget *progress = gtk_progress_bar_new();
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(progress), (gdouble)MIN(completed, total) / (gdouble)total);
        gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(progress), TRUE);
        gchar *completed_text = g_format_size(completed);
        gchar *total_text = g_format_size(total);
        gchar *progress_text = g_strdup_printf("%s of %s", completed_text, total_text);
        gtk_progress_bar_set_text(GTK_PROGRESS_BAR(progress), progress_text);
        g_free(completed_text);
        g_free(total_text);
        g_free(progress_text);
        gtk_box_append(GTK_BOX(outer), progress);
    } else if (g_strcmp0(job->state, "downloading") == 0) {
        GtkWidget *progress = gtk_progress_bar_new();
        gtk_progress_bar_pulse(GTK_PROGRESS_BAR(progress));
        gtk_box_append(GTK_BOX(outer), progress);
    }
    if (job->error_message != NULL) {
        GtkWidget *error_label = gtk_label_new(job->error_message);
        gtk_label_set_xalign(GTK_LABEL(error_label), 0.0f);
        gtk_label_set_wrap(GTK_LABEL(error_label), TRUE);
        gtk_widget_add_css_class(error_label, "error");
        gtk_box_append(GTK_BOX(outer), error_label);
    }
    GtkWidget *destination_label = gtk_label_new(job->destination);
    gtk_label_set_xalign(GTK_LABEL(destination_label), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(destination_label), PANGO_ELLIPSIZE_MIDDLE);
    gtk_widget_add_css_class(destination_label, "dim-label");
    gtk_box_append(GTK_BOX(outer), destination_label);

    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    if (g_strcmp0(job->state, "queued") == 0 || g_strcmp0(job->state, "scheduled") == 0 || g_strcmp0(job->state, "retry_wait") == 0) {
        if (g_strcmp0(job->state, "queued") == 0 || g_strcmp0(job->state, "retry_wait") == 0)
            add_action_button(actions, app, job, g_strcmp0(job->state, "retry_wait") == 0 ? "Retry" : "Start", "start");
        add_action_button(actions, app, job, "Pause", "pause");
        add_action_button(actions, app, job, "Cancel", "cancel");
    } else if (g_strcmp0(job->state, "downloading") == 0) {
        if (job->requested_control != NULL) {
            GtkWidget *pending = gtk_label_new(g_strcmp0(job->requested_control, "pause") == 0 ? "Pausing…" : "Canceling…");
            gtk_box_append(GTK_BOX(actions), pending);
        } else {
            add_action_button(actions, app, job, "Pause", "pause");
            add_action_button(actions, app, job, "Cancel", "cancel");
        }
    } else if (g_strcmp0(job->state, "paused") == 0) {
        add_action_button(actions, app, job, "Resume", "resume");
        add_action_button(actions, app, job, "Cancel", "cancel");
    } else if (g_strcmp0(job->state, "failed") == 0) {
        add_action_button(actions, app, job, "Retry", "retry");
    }
    gtk_box_append(GTK_BOX(outer), actions);
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), outer);
    return row;
}

static void replace_jobs(AppState *app, GPtrArray *jobs) {
    GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(app->job_list));
    while (child != NULL) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_list_box_remove(app->job_list, child);
        child = next;
    }
    for (guint i = 0; i < jobs->len; i++) {
        DownloadJob *job = g_ptr_array_index(jobs, i);
        gtk_list_box_append(app->job_list, create_job_row(app, job));
    }
}

static JsonNode *build_list_params(guint offset) {
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "offset"); json_builder_add_int_value(builder, offset);
    json_builder_set_member_name(builder, "limit"); json_builder_add_int_value(builder, 100);
    json_builder_end_object(builder);
    JsonNode *node = json_builder_get_root(builder);
    g_object_unref(builder);
    return node;
}

static GPtrArray *fetch_all_jobs(GCancellable *cancellable, GError **error) {
    GPtrArray *all_jobs = g_ptr_array_new_with_free_func(download_job_free);
    guint offset = 0;
    for (;;) {
        JsonNode *params = build_list_params(offset);
        JsonNode *result = rpc_call("jobs.list", params, cancellable, error);
        json_node_unref(params);
        if (result == NULL) {
            g_ptr_array_unref(all_jobs);
            return NULL;
        }
        GPtrArray *page = parse_jobs(result, error);
        JsonObject *object = JSON_NODE_HOLDS_OBJECT(result) ? json_node_get_object(result) : NULL;
        const gchar *next_value = json_string(object, "next_offset");
        gchar *next_text = next_value != NULL ? g_strdup(next_value) : NULL;
        json_node_unref(result);
        if (page == NULL) {
            g_ptr_array_unref(all_jobs);
            g_free(next_text);
            return NULL;
        }
        while (page->len > 0) g_ptr_array_add(all_jobs, g_ptr_array_steal_index(page, 0));
        g_ptr_array_unref(page);
        if (next_text == NULL) return all_jobs;

        gchar *end = NULL;
        guint64 next = g_ascii_strtoull(next_text, &end, 10);
        gboolean valid_cursor = end != next_text && end != NULL && *end == '\0' && next > offset && next <= G_MAXUINT;
        g_free(next_text);
        if (!valid_cursor) {
            g_ptr_array_unref(all_jobs);
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Engine returned an invalid job-list cursor.");
            return NULL;
        }
        offset = (guint)next;
    }
}

static void rpc_worker(GTask *task, gpointer source_object, gpointer task_data, GCancellable *cancellable) {
    (void)source_object;
    RpcTask *request = task_data;
    GError *error = NULL;
    if (request->refresh) {
        GPtrArray *jobs = fetch_all_jobs(cancellable, &error);
        if (jobs == NULL) g_task_return_error(task, error);
        else g_task_return_pointer(task, jobs, (GDestroyNotify)g_ptr_array_unref);
        return;
    }
    JsonNode *result = rpc_call(request->method, request->params, cancellable, &error);
    if (result == NULL) g_task_return_error(task, error);
    else g_task_return_pointer(task, result, (GDestroyNotify)json_node_unref);
}

static void rpc_finished(GObject *source_object, GAsyncResult *result, gpointer user_data) {
    (void)source_object;
    AppState *app = user_data;
    GTask *task = G_TASK(result);
    RpcTask *request = g_task_get_task_data(task);
    GError *error = NULL;
    gpointer response = g_task_propagate_pointer(task, &error);
    if (request->refresh) app->refresh_in_flight = FALSE;
    if (error != NULL) {
        gtk_label_set_text(app->connection_status, "Engine disconnected");
        set_message(app, error->message, TRUE);
        g_clear_error(&error);
        if (!request->refresh) refresh_jobs(app);
        return;
    }
    gtk_label_set_text(app->connection_status, "Engine connected");
    if (request->refresh) {
        GPtrArray *jobs = response;
        replace_jobs(app, jobs);
        g_ptr_array_unref(jobs);
        set_message(app, "", FALSE);
    } else {
        set_message(app, "Request completed.", FALSE);
        refresh_jobs(app);
        json_node_unref(response);
    }
}

static void start_rpc(AppState *app, const gchar *method, JsonNode *params, gboolean refresh) {
    GTask *task = g_task_new(NULL, NULL, rpc_finished, app);
    RpcTask *request = g_new0(RpcTask, 1);
    request->method = g_strdup(method);
    request->params = params != NULL ? json_node_copy(params) : NULL;
    request->refresh = refresh;
    g_task_set_task_data(task, request, rpc_task_free);
    g_task_run_in_thread(task, rpc_worker);
    g_object_unref(task);
}

static gboolean refresh_jobs(AppState *app) {
    if (app->refresh_in_flight) return G_SOURCE_CONTINUE;
    app->refresh_in_flight = TRUE;
    start_rpc(app, "jobs.list", NULL, TRUE);
    return G_SOURCE_CONTINUE;
}

static gboolean refresh_timer(gpointer user_data) {
    return refresh_jobs(user_data);
}

static JsonNode *control_params(const gchar *job_id, const gchar *action, const gchar *revision) {
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "job_id"); json_builder_add_string_value(builder, job_id);
    json_builder_set_member_name(builder, "action"); json_builder_add_string_value(builder, action);
    json_builder_set_member_name(builder, "expected_revision"); json_builder_add_string_value(builder, revision);
    json_builder_end_object(builder);
    JsonNode *node = json_builder_get_root(builder);
    g_object_unref(builder);
    return node;
}

static void on_job_action(GtkButton *button, gpointer user_data) {
    AppState *app = user_data;
    const gchar *job_id = g_object_get_data(G_OBJECT(button), "job-id");
    const gchar *revision = g_object_get_data(G_OBJECT(button), "revision");
    const gchar *action = g_object_get_data(G_OBJECT(button), "action");
    JsonNode *params = control_params(job_id, action, revision);
    start_rpc(app, "jobs.control", params, FALSE);
    json_node_unref(params);
}

typedef struct {
    AppState *app;
    GtkWidget *dialog;
    GtkWidget *url;
    GtkWidget *name;
    GtkWidget *destination;
    GtkWidget *priority;
} AddDialog;

static void add_dialog_free(AddDialog *form) {
    g_free(form);
}

static JsonNode *add_params(const gchar *url, const gchar *name, const gchar *destination, gint priority) {
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "url"); json_builder_add_string_value(builder, url);
    if (name[0] != '\0') { json_builder_set_member_name(builder, "name"); json_builder_add_string_value(builder, name); }
    json_builder_set_member_name(builder, "destination"); json_builder_add_string_value(builder, destination);
    json_builder_set_member_name(builder, "priority"); json_builder_add_int_value(builder, priority);
    json_builder_set_member_name(builder, "idempotency_key");
    gchar *key = g_uuid_string_random(); json_builder_add_string_value(builder, key); g_free(key);
    json_builder_end_object(builder);
    JsonNode *node = json_builder_get_root(builder);
    g_object_unref(builder);
    return node;
}

static void add_dialog_response(GtkDialog *dialog, gint response_id, gpointer user_data) {
    AddDialog *form = user_data;
    if (response_id == GTK_RESPONSE_ACCEPT) {
        const gchar *url_text = gtk_editable_get_text(GTK_EDITABLE(form->url));
        const gchar *name_text = gtk_editable_get_text(GTK_EDITABLE(form->name));
        const gchar *destination_text = gtk_editable_get_text(GTK_EDITABLE(form->destination));
        GError *error = NULL;
        GUri *uri = g_uri_parse(url_text, G_URI_FLAGS_NONE, &error);
        const gchar *scheme = uri != NULL ? g_uri_get_scheme(uri) : NULL;
        const gchar *host = uri != NULL ? g_uri_get_host(uri) : NULL;
        gboolean valid_scheme = scheme != NULL && (g_ascii_strcasecmp(scheme, "http") == 0 || g_ascii_strcasecmp(scheme, "https") == 0);
        if (uri == NULL || !valid_scheme || host == NULL || !g_path_is_absolute(destination_text) || !g_file_test(destination_text, G_FILE_TEST_IS_DIR)) {
            set_message(form->app, error != NULL ? error->message : "Enter a valid HTTP(S) URL and an existing absolute folder.", TRUE);
            g_clear_error(&error);
            if (uri != NULL) g_uri_unref(uri);
            return;
        }
        g_uri_unref(uri);
        gint priority = gtk_drop_down_get_selected(GTK_DROP_DOWN(form->priority));
        priority = priority == 0 ? -1 : priority == 2 ? 1 : 0;
        JsonNode *params = add_params(url_text, name_text, destination_text, priority);
        start_rpc(form->app, "jobs.add", params, FALSE);
        json_node_unref(params);
        gtk_window_destroy(GTK_WINDOW(dialog));
        add_dialog_free(form);
        return;
    }
    gtk_window_destroy(GTK_WINDOW(dialog));
    add_dialog_free(form);
}

static void on_add_download(GtkButton *button, gpointer user_data) {
    (void)button;
    AppState *app = user_data;
    GtkWidget *dialog = gtk_dialog_new();
    gtk_window_set_title(GTK_WINDOW(dialog), "Add Download");
    gtk_window_set_transient_for(GTK_WINDOW(dialog), app->window);
    gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
    gtk_dialog_add_button(GTK_DIALOG(dialog), "Cancel", GTK_RESPONSE_CANCEL);
    gtk_dialog_add_button(GTK_DIALOG(dialog), "Add to Queue", GTK_RESPONSE_ACCEPT);
    GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    gtk_box_set_spacing(GTK_BOX(content), 10);
    gtk_widget_set_margin_top(content, 16);
    gtk_widget_set_margin_bottom(content, 16);
    gtk_widget_set_margin_start(content, 16);
    gtk_widget_set_margin_end(content, 16);

    AddDialog *form = g_new0(AddDialog, 1);
    form->app = app;
    form->dialog = dialog;
    form->url = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(form->url), "https://example.com/file.zip");
    form->name = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(form->name), "Name (optional)");
    form->destination = gtk_entry_new();
    const gchar *downloads = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD);
    gtk_editable_set_text(GTK_EDITABLE(form->destination), downloads != NULL ? downloads : g_get_home_dir());
    const gchar *choices[] = { "Low", "Normal", "High", NULL };
    form->priority = gtk_drop_down_new_from_strings(choices);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(form->priority), 1);

    gtk_box_append(GTK_BOX(content), gtk_label_new("URL")); gtk_box_append(GTK_BOX(content), form->url);
    gtk_box_append(GTK_BOX(content), gtk_label_new("Name")); gtk_box_append(GTK_BOX(content), form->name);
    gtk_box_append(GTK_BOX(content), gtk_label_new("Destination folder")); gtk_box_append(GTK_BOX(content), form->destination);
    gtk_box_append(GTK_BOX(content), gtk_label_new("Priority")); gtk_box_append(GTK_BOX(content), form->priority);
    g_signal_connect(dialog, "response", G_CALLBACK(add_dialog_response), form);
    gtk_window_present(GTK_WINDOW(dialog));
}

static void on_refresh(GtkButton *button, gpointer user_data) {
    (void)button;
    refresh_jobs(user_data);
}

static void on_activate(GtkApplication *application, gpointer user_data) {
    AppState *app = user_data;
    app->application = application;
    app->window = GTK_WINDOW(gtk_application_window_new(application));
    gtk_window_set_title(app->window, "Speed Download");
    gtk_window_set_default_size(app->window, 1000, 720);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *header = gtk_header_bar_new();
    GtkWidget *title = gtk_label_new("Speed Download");
    gtk_widget_add_css_class(title, "title");
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), title);
    GtkWidget *add = gtk_button_new_with_label("Add Download");
    g_signal_connect(add, "clicked", G_CALLBACK(on_add_download), app);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), add);
    GtkWidget *refresh = gtk_button_new_from_icon_name("view-refresh-symbolic");
    gtk_widget_set_tooltip_text(refresh, "Refresh downloads");
    g_signal_connect(refresh, "clicked", G_CALLBACK(on_refresh), app);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), refresh);
    gtk_box_append(GTK_BOX(root), header);

    app->connection_status = GTK_LABEL(gtk_label_new("Connecting to engine…"));
    gtk_label_set_xalign(app->connection_status, 0.0f);
    gtk_widget_set_margin_top(GTK_WIDGET(app->connection_status), 10);
    gtk_widget_set_margin_start(GTK_WIDGET(app->connection_status), 16);
    gtk_box_append(GTK_BOX(root), GTK_WIDGET(app->connection_status));
    app->message_status = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_xalign(app->message_status, 0.0f);
    gtk_label_set_wrap(app->message_status, TRUE);
    gtk_widget_set_margin_start(GTK_WIDGET(app->message_status), 16);
    gtk_widget_set_margin_end(GTK_WIDGET(app->message_status), 16);
    gtk_widget_set_visible(GTK_WIDGET(app->message_status), FALSE);
    gtk_box_append(GTK_BOX(root), GTK_WIDGET(app->message_status));

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    app->job_list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_list_box_set_selection_mode(app->job_list, GTK_SELECTION_NONE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(app->job_list));
    gtk_box_append(GTK_BOX(root), scroll);
    gtk_window_set_child(app->window, root);
    gtk_window_present(app->window);
    refresh_jobs(app);
    g_timeout_add_seconds(REFRESH_INTERVAL_SECONDS, refresh_timer, app);
}

int main(int argc, char **argv) {
    AppState app = {0};
    GtkApplication *application = gtk_application_new("org.speeddownload.SpeedDownload", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(application, "activate", G_CALLBACK(on_activate), &app);
    int status = g_application_run(G_APPLICATION(application), argc, argv);
    g_object_unref(application);
    return status;
}
