/**
 * Copyright (c) 2026 Bao Han <erbws@qq.com>
 */

#ifndef JSON_H
#define JSON_H

#include <mpv/client.h>
#include <aki/jsbind.h>

aki::Value mpv_node_to_aki_value(const mpv_node& node);
std::string json_stringify(const mpv_node& node);

#endif