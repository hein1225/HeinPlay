/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 */

#include <cmath>
#include <string>

#include "globals.h"
#include "log.h"

void NativePlayer::set_option_string(const std::string& option, const std::string& value) const
{
    if (!handle) {
        log_e("[napi:set_option_string] mpv is not initialized");
        return;
    }

    mpv_set_option_string(handle, option.c_str(), value.c_str());
}

double NativePlayer::get_property(const std::string& property) const
{
    if (!handle) {
        log_e("[napi:get_property] mpv is not initialized");
        return 0;
    }

    double value = 0;

    // mpv_get_property() can convert int64_t to double losslessly.
    // They all result 'number', so only query double value to make code clean.
    mpv_get_property(handle, property.c_str(), MPV_FORMAT_DOUBLE, &value);

    return value;
}

// HeinPlay 2026-10-07：属性读取的**可失败版本**，失败时返回 NaN。
//
// 为什么必须新增而不是复用 get_property：
//   上面的 get_property 丢弃了 mpv_get_property() 的返回值，属性不可用时
//   （demuxer 还没建、还没开始缓冲等）**静默返回 0**。
//   但 0 同时也是一个合法读数（缓存恰好为 0），调用方无从区分
//   「读不到」与「读到 0」。
//   而硬解归因判定恰恰依赖这个区别：
//     demuxer-cache-time 读不到 → 数据还没到（源慢）
//     demuxer-cache-time 读到 0  → 数据到了但已耗尽
//   把两者混为一谈会直接导致「源慢」被误判成「硬解失败」。
//
// 返回约定：成功返回真实读数（含 0）；失败返回 NaN。
// NaN 是唯一安全的失败哨兵 —— JS 侧用 isNaN() 判定，
// 不会与任何真实读数（含 0）混淆。
// 注意：aki 无法把 C++ 引用出参映射到 JS，故这里不做 bool+out 参数，
// 而是直接把失败编码进返回值本身。
double NativePlayer::get_property_or_nan(const std::string& property) const
{
    if (!handle) {
        log_e("[napi:get_property_or_nan] mpv is not initialized");
        return std::nan("");
    }

    double value = 0;
    int rc = mpv_get_property(handle, property.c_str(), MPV_FORMAT_DOUBLE, &value);
    if (rc < 0) {
        // 属性当前不可用（UNAVAILABLE/FORMAT_ERROR 等）——这是**信息**，不是错误，
        // 故只记 trace 级，不用 log_e 刷屏。
        return std::nan("");
    }
    return value;
}

bool NativePlayer::get_property_bool(const std::string& property) const
{
    if (!handle) {
        log_e("[napi:get_property_bool] mpv is not initialized");
        return false;
    }

    int value = 0;

    mpv_get_property(handle, property.c_str(), MPV_FORMAT_FLAG, &value);

    return value != 0;
}

std::string NativePlayer::get_property_string(const std::string& property) const
{
    if (!handle) {
        log_e("[napi:get_property_string] mpv is not initialized");
        return {};
    }

    char* value = mpv_get_property_string(handle, property.c_str());
    if (!value) {
        return "";
    }

    std::string result = value;
    mpv_free(value);

    return result;
}

void NativePlayer::set_property_int(const std::string& property, int64_t value) const
{
    if (!handle) {
        log_e("[napi:set_property_int] mpv is not initialized");
        return;
    }

    mpv_set_property(handle, property.c_str(), MPV_FORMAT_INT64, &value);
}

void NativePlayer::set_property_double(const std::string& property, double value) const
{
    if (!handle) {
        log_e("[napi:set_property_double] mpv is not initialized");
        return;
    }

    mpv_set_property(handle, property.c_str(), MPV_FORMAT_DOUBLE, &value);
}

void NativePlayer::set_property_bool(const std::string& property, const bool value) const
{
    if (!handle) {
        log_e("[napi:set_property_bool] mpv is not initialized");
        return;
    }

    int flag = value ? 1 : 0;
    mpv_set_property(handle, property.c_str(), MPV_FORMAT_FLAG, &flag);
}

void NativePlayer::set_property_string(const std::string& property, const std::string& value) const
{
    if (!handle) {
        log_e("[napi:set_property_string] mpv is not initialized");
        return;
    }

    mpv_set_property_string(handle, property.c_str(), value.c_str());
}



void NativePlayer::observe_property(const std::string& property, uint8_t format) const
{
    if (!handle) {
        log_e("[napi:observe_property] mpv is not initialized");
        return;
    }

    // 🔴 HeinPlay 修复（2026-10-08）：原先这里**丢弃了返回值**：
    //       mpv_observe_property(handle, 0, property.c_str(), fmt);
    //   mpv 对未知/暂不可用的属性会返回 MPV_ERROR_PROPERTY_NOT_FOUND 而不是
    //   抛异常，静默失败后该属性**永远不会**产生 property-change 回调。
    //
    //   【真机后果】h14 日志铁证：mpv 播放会话（21:00:11–21:02:06）内
    //     `time-pos/full` 的 property-change 回调**一次都没有触发**，
    //     原生侧从未上报过 position，Dart `_position` 全程钉死在 890000ms
    //     （= open 时传入的 start 值），而 AVP 侧同期有 224 条进度上报。
    //     表现即用户所见：「mpv 播放中进度条时间不动」。
    //
    //   【为什么必须记录错误码】「读不到」与「读到 0」必须可区分
    //     （与 get_property_or_nan 同一原则）。observe 失败属于「读不到」，
    //     绝不能与「属性值恰为 0」混淆，否则会误判成「上报了但值为 0」
    //     而在错误方向排查。
    //
    //   【为什么额外读一次初值】mpv_observe_property 只在属性**变化**时回调。
    //     主动 get 一次可保证注册期就建立一个基准值，也让「注册时属性是否
    //     已可用」在日志中可见 —— 这正是区分「注册失败」与「注册成功但
    //     播放尚未开始」的关键证据。
    //
    //   注：log_i/log_e 只接受单个 const char*（见 log.h），故先拼字符串。
    const int err = mpv_observe_property(handle, 0, property.c_str(),
                                         static_cast<mpv_format>(format));
    if (err < 0) {
        log_e(("[napi:observe_property] 注册失败 prop=" + property
               + " fmt=" + std::to_string(static_cast<int>(format))
               + " err=" + std::to_string(err)
               + "(" + mpv_error_string(err) + ")").c_str());
        return;
    }

    // 注册成功后立即读一次当前值作为首帧基准（读取失败不算错，仅记录）。
    double cur = 0;
    const int get_err = mpv_get_property(handle, property.c_str(),
                                         MPV_FORMAT_DOUBLE, &cur);
    log_i(("[napi:observe_property] 已注册 prop=" + property
           + " fmt=" + std::to_string(static_cast<int>(format))
           + " 初值="
           + (get_err < 0 ? std::string("N/A(暂不可用)")
                          : std::to_string(cur))).c_str());
}
