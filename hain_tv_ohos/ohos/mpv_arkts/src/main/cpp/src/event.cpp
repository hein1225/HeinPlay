/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 *
 * fuck napi
 */

#include <string>

#include <hilog/log.h>
#include <aki/task_runner/task_runner.h>
#include "globals.h"
#include "node.h"

static const struct {
    LogLevel level;
    mpv_log_level mpv_level;
} level_map[] = {
    {LOG_FATAL, MPV_LOG_LEVEL_FATAL},
    {LOG_ERROR, MPV_LOG_LEVEL_ERROR},
    {LOG_WARN, MPV_LOG_LEVEL_WARN},
    {LOG_INFO, MPV_LOG_LEVEL_INFO},
    {LOG_DEBUG, MPV_LOG_LEVEL_V},
    {LOG_DEBUG, MPV_LOG_LEVEL_DEBUG},
    {LOG_DEBUG, MPV_LOG_LEVEL_TRACE},
    {LOG_INFO, MPV_LOG_LEVEL_NONE},
};

static LogLevel to_level(const mpv_log_level mpv_level)
{
    for (auto [level, source_level] : level_map) {
        if (source_level == mpv_level)
            return level;
    }

    return LOG_INFO;
}

static void dispatch_property_change(const std::string& property_name)
{
    aki::TaskRunner::PostTask("main", [property_name] {
        if (const auto tsfn = aki::JSBind::GetJSFunction("property"); tsfn != nullptr) {
            tsfn->Invoke<void>(property_name);
        }
    });
}

template<typename T>
static void dispatch_property_change(const std::string& property_name, const T& value)
{
    aki::TaskRunner::PostTask("main", [property_name, value] {
        if (const auto tsfn = aki::JSBind::GetJSFunction("property"); tsfn != nullptr) {
            tsfn->Invoke<void>(property_name, value);
        }
    });
}

static void dispatch_event(uint32_t event_id, const std::string& event_name)
{
    aki::TaskRunner::PostTask("main", [event_id, event_name] {
        if (const auto tsfn = aki::JSBind::GetJSFunction("event"); tsfn != nullptr) {
            tsfn->Invoke<void>(event_id, event_name);
        }
    });
}

static void dispatch_log_message(const std::string& prefix, const std::string& level, const std::string& message)
{
    aki::TaskRunner::PostTask("main", [prefix, level, message] {
        if (const auto tsfn = aki::JSBind::GetJSFunction("log"); tsfn != nullptr) {
            tsfn->Invoke<void>(prefix, level, message);
        }
    });
}

static void emit_property_change(const mpv_event_property* property)
{
    if (property == nullptr || property->name == nullptr) {
        return;
    }

    const std::string property_name(property->name);

    if (property->data == nullptr || property->format == MPV_FORMAT_NONE) {
        dispatch_property_change(property_name);
        return;
    }

    switch (property->format) {
    case MPV_FORMAT_STRING:
    case MPV_FORMAT_OSD_STRING:
        dispatch_property_change(property_name, *static_cast<char* const*>(property->data));
        break;
    case MPV_FORMAT_FLAG:
        dispatch_property_change(property_name, *static_cast<const int*>(property->data) != 0);
        break;
    case MPV_FORMAT_INT64:
        dispatch_property_change(property_name, *static_cast<const int64_t*>(property->data));
        break;
    case MPV_FORMAT_DOUBLE:
        dispatch_property_change(property_name, *static_cast<const double*>(property->data));
        break;
    case MPV_FORMAT_NODE:
        dispatch_property_change(property_name, json_stringify(*static_cast<const mpv_node*>(property->data)));
        break;
    default:
        dispatch_property_change(property_name);
        break;
    }
}

void NativePlayer::thread_event() const
{
    while (true) {
        mpv_event_property* property = nullptr;
        mpv_event_log_message* msg = nullptr;

        mpv_event* event = mpv_wait_event(handle, -1.0);

        if (request_thread_exit)
            break;

        if (event->event_id == MPV_EVENT_NONE)
            continue;

        switch (event->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE:
            property = static_cast<mpv_event_property*>(event->data);
            emit_property_change(property);
            break;
        case MPV_EVENT_LOG_MESSAGE:
            msg = static_cast<mpv_event_log_message*>(event->data);
            if (msg == nullptr)
                break;
            dispatch_log_message(msg->prefix, msg->level, msg->text);
            break;
        default:
            dispatch_event(event->event_id, mpv_event_name(event->event_id));
            break;
        }
    }
}
