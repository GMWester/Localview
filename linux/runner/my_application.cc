#include "my_application.h"

#include <cstring>

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Keep running in the background: closing the window hides it (with a tray icon
// on desktops that show one) while Localview has connections or is hosting.
static gboolean keep_alive = FALSE;
static GtkWindow* main_window = nullptr;
static FlMethodChannel* main_channel = nullptr;
static GtkStatusIcon* tray_icon = nullptr;

static void notify_hidden(gboolean hidden) {
  if (main_channel == nullptr) return;
  g_autoptr(FlValue) v = fl_value_new_bool(hidden);
  fl_method_channel_invoke_method(main_channel, "hidden", v, nullptr, nullptr, nullptr);
}

static void remove_tray() {
  if (tray_icon == nullptr) return;
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  gtk_status_icon_set_visible(tray_icon, FALSE);
  G_GNUC_END_IGNORE_DEPRECATIONS
  g_clear_object(&tray_icon);
}

static void show_window() {
  if (main_window == nullptr) return;
  gtk_widget_show(GTK_WIDGET(main_window));
  gtk_window_present(main_window);
  remove_tray();
  notify_hidden(FALSE);
}

static void tray_activate_cb(GtkStatusIcon*, gpointer) { show_window(); }

static void tray_quit_cb(GtkMenuItem*, gpointer) {
  keep_alive = FALSE;
  remove_tray();
  if (main_window != nullptr) gtk_widget_destroy(GTK_WIDGET(main_window));
}

static void tray_open_cb(GtkMenuItem*, gpointer) { show_window(); }

static void tray_popup_cb(GtkStatusIcon*, guint, guint, gpointer) {
  GtkWidget* menu = gtk_menu_new();
  GtkWidget* open = gtk_menu_item_new_with_label("Open Localview");
  GtkWidget* quit = gtk_menu_item_new_with_label("Quit (disconnects)");
  g_signal_connect(open, "activate", G_CALLBACK(tray_open_cb), nullptr);
  g_signal_connect(quit, "activate", G_CALLBACK(tray_quit_cb), nullptr);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), open);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit);
  gtk_widget_show_all(menu);
  gtk_menu_popup_at_pointer(GTK_MENU(menu), nullptr);
}

static void hide_window() {
  if (main_window == nullptr) return;
  gtk_widget_hide(GTK_WIDGET(main_window));
  if (tray_icon == nullptr) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    tray_icon = gtk_status_icon_new_from_icon_name("io.localview.localview");
    gtk_status_icon_set_tooltip_text(tray_icon, "Localview (running in the background)");
    gtk_status_icon_set_title(tray_icon, "Localview");
    G_GNUC_END_IGNORE_DEPRECATIONS
    g_signal_connect(tray_icon, "activate", G_CALLBACK(tray_activate_cb), nullptr);
    g_signal_connect(tray_icon, "popup-menu", G_CALLBACK(tray_popup_cb), nullptr);
  }
  notify_hidden(TRUE);
}

// Called when first Flutter frame received.
// "localview/window" channel: fullscreen for Theater mode (Steam Frame /
// Steam Deck / desktop). Runs on the GTK main thread.
static void window_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(fl_method_call_get_name(call), "setFullscreen") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    gboolean on = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                  fl_value_get_bool(args);
    if (on) {
      gtk_window_fullscreen(window);
    } else {
      gtk_window_unfullscreen(window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(fl_method_call_get_name(call), "setKeepAlive") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    FlValue* on = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                      ? fl_value_lookup_string(args, "on")
                      : nullptr;
    keep_alive = on != nullptr && fl_value_get_type(on) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(on);
    // Nothing left to keep alive while hidden: quit as a normal close would have.
    if (!keep_alive && main_window != nullptr && !gtk_widget_get_visible(GTK_WIDGET(main_window))) {
      remove_tray();
      gtk_widget_destroy(GTK_WIDGET(main_window));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(fl_method_call_get_name(call), "hide") == 0) {
    hide_window();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(fl_method_call_get_name(call), "show") == 0) {
    show_window();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_default_size(window, 1280, 720);

  // If you want to use a header bar, uncomment the following lines.
  // Header bars are commonly used in GNOME based desktop environments and
  // allow additional widgets to be added to the title bar.
  // See https://docs.gtk.org/gtk3/class.HeaderBar.html
  // GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
  // gtk_widget_show(GTK_WIDGET(header_bar));
  // gtk_header_bar_set_show_close_button(header_bar, TRUE);
  // gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));

  // Extra viewer windows get their device / monitor as the title.
  const gchar* viewer_title = g_getenv("LOCALVIEW_VIEWER_TITLE");
  gtk_window_set_title(window, viewer_title != nullptr ? viewer_title : "Localview");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "localview/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(window_channel, window_method_cb, window,
                                            nullptr);
  main_window = window;
  main_channel = window_channel;

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
