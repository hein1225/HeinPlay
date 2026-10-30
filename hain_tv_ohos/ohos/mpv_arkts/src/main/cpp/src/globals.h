/**
 * Copyright (c) 2026 Bao Han <erbws@qq.com>
 */

#ifndef GLOBALS_H
#define GLOBALS_H

#include <atomic>
#include <map>
#include <thread>

#include <aki/jsbind.h>
#include <mpv/client.h>

class NativePlayer
{
    mpv_handle* handle = nullptr;
    std::atomic<bool> request_thread_exit = false;
    std::thread thread;

    void thread_event() const;

public:
    void create();
    void initialize();
    void destroy();
    void attach_surface(const std::string& surface) const;
    void detach_surface() const;
    void command(const std::vector<std::string>& commands) const;
    aki::Value command_with_return(const std::vector<std::string>& commands) const;
    void load_file(const std::string& url, const std::map<std::string, std::string>& options) const;
    void request_log_messages(const std::string& level) const;
    void set_option_string(const std::string& option, const std::string& value) const;
    double get_property(const std::string& property) const;
    double get_property_or_nan(const std::string& property) const;
    bool get_property_bool(const std::string& property) const;
    std::string get_property_string(const std::string& property) const;
    void set_property_int(const std::string& property, int64_t value) const;
    void set_property_double(const std::string& property, double value) const;
    void set_property_bool(const std::string& property, bool value) const;
    void set_property_string(const std::string& property, const std::string& value) const;
    void observe_property(const std::string& option, uint8_t format) const;
};

#endif
