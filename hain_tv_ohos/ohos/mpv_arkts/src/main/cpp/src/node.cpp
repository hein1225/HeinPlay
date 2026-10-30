/**
 * Copyright (c) 2026 Bao Han <erbws@qq.com>
 */

#include <simdjson.h>
#include "node.h"

static std::string base64_encode(const uint8_t* data, const size_t len)
{
    static constexpr char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    std::string output;
    output.reserve((len + 2) / 3 * 4);

    for (size_t index = 0; index < len; index += 3) {
        const uint32_t chunk = static_cast<uint32_t>(data[index]) << 16
            | (index + 1 < len ? static_cast<uint32_t>(data[index + 1]) : 0U) << 8
            | (index + 2 < len ? static_cast<uint32_t>(data[index + 2]) : 0U);

        output.push_back(alphabet[chunk >> 18 & 0x3F]);
        output.push_back(alphabet[chunk >> 12 & 0x3F]);
        output.push_back(index + 1 < len ? alphabet[chunk >> 6 & 0x3F] : '=');
        output.push_back(index + 2 < len ? alphabet[chunk & 0x3F] : '=');
    }

    return output;
}

static void append_json_value(simdjson::arm64::builder::string_builder& builder, const mpv_node& node)
{
    switch (node.format) {
    case MPV_FORMAT_STRING:
        builder.escape_and_append_with_quotes(node.u.string);
        break;

    case MPV_FORMAT_FLAG:
        builder.append(node.u.flag > 0);
        break;

    case MPV_FORMAT_INT64:
        builder.append(node.u.int64);
        break;

    case MPV_FORMAT_DOUBLE:
        builder.append(node.u.double_);
        break;

    case MPV_FORMAT_NODE_ARRAY:
        builder.start_array();
        if (node.u.list->num > 0) {
            for (int i = 0; i < node.u.list->num; i++) {
                if (i > 0)
                    builder.append_comma();
                append_json_value(builder, node.u.list->values[i]);
            }
        }
        builder.end_array();
        break;

    case MPV_FORMAT_NODE_MAP:
        builder.start_object();
        if (node.u.list->num > 0) {
            for (int i = 0; i < node.u.list->num; i++) {
                if (i > 0)
                    builder.append_comma();
                builder.escape_and_append_with_quotes(node.u.list->keys[i]);
                builder.append_colon();
                append_json_value(builder, node.u.list->values[i]);
            }
        }
        builder.end_object();
        break;

    case MPV_FORMAT_BYTE_ARRAY:
        builder.escape_and_append_with_quotes(
            base64_encode(static_cast<const uint8_t*>(node.u.ba->data), node.u.ba->size));
        break;

    default:
        builder.append_null();
        break;
    }
}

std::string json_stringify(const mpv_node& node)
{
    simdjson::arm64::builder::string_builder builder;
    append_json_value(builder, node);

    std::string_view view;
    if (builder.view().get(view)) {
        return "null";
    }

    return std::string(view);
}

aki::Value mpv_node_to_aki_value(const mpv_node& node)
{
    switch (node.format) {
    case MPV_FORMAT_STRING:
        return aki::Value(std::string(node.u.string));
    case MPV_FORMAT_FLAG:
        return aki::Value(node.u.flag > 0);
    case MPV_FORMAT_INT64:
        return aki::Value(static_cast<int64_t>(node.u.int64));
    case MPV_FORMAT_DOUBLE:
        return aki::Value(static_cast<double>(node.u.double_));
    case MPV_FORMAT_NODE_ARRAY: {
        aki::Value arr = aki::Value::NewArray();
        if (node.u.list->num > 0) {
            for (int i = 0; i < node.u.list->num; i++) {
                arr.Set(i, mpv_node_to_aki_value(node.u.list->values[i]).GetHandle());
            }
        }
        return arr;
    }
    case MPV_FORMAT_NODE_MAP: {
        aki::Value obj = aki::Value::NewObject();
        if (node.u.list->num > 0) {
            for (int i = 0; i < node.u.list->num; i++) {
                obj.Set(node.u.list->keys[i], mpv_node_to_aki_value(node.u.list->values[i]).GetHandle());
            }
        }
        return obj;
    }
    case MPV_FORMAT_BYTE_ARRAY: {
        return aki::Value(aki::ArrayBuffer(
            static_cast<uint8_t*>(node.u.ba->data),
            node.u.ba->size,
            aki::ArrayBuffer::BUFF));
    }
    default:
        return aki::Value::NewObject();
    }
}
