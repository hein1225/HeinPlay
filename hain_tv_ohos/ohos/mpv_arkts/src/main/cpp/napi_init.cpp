/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 *
 * fuck napi
 */

#include "src/globals.h"
#include "src/log.h"

// 🔴 2026-10-07：此处曾有一个 constructor 装载探针，用于区分「so 未 dlopen」
//   与「aki 注册失败」。根因已定位（自编译 libmpv.so 缺 openssl 符号导致
//   dlopen 失败），探针已完成使命，移除以免干扰后续排查。
//   判据改为应用层日志：aki 会打印 "register AKI addon: mpv_wrapper"。

JSBIND_CLASS(NativePlayer)
{
    JSBIND_CONSTRUCTOR<>();
    JSBIND_METHOD(create);
    JSBIND_METHOD(initialize);
    JSBIND_METHOD(destroy);
    JSBIND_METHOD(attach_surface, "attachSurface");
    JSBIND_METHOD(detach_surface, "detachSurface");
    JSBIND_METHOD(command);
    JSBIND_METHOD(command_with_return, "commandWithReturn");
    JSBIND_METHOD(load_file, "loadFile");
    JSBIND_METHOD(request_log_messages, "requestLogMessages");
    JSBIND_METHOD(set_option_string, "setOptionString");
    JSBIND_METHOD(get_property, "getProperty");
    JSBIND_METHOD(get_property_or_nan, "getPropertyOrNaN");
    JSBIND_METHOD(get_property_bool, "getPropertyBool");
    JSBIND_METHOD(get_property_string, "getPropertyString");
    JSBIND_METHOD(set_property_int, "setPropertyInt");
    JSBIND_METHOD(set_property_double, "setPropertyDouble");
    JSBIND_METHOD(set_property_bool, "setPropertyBool");
    JSBIND_METHOD(set_property_string, "setPropertyString");
    JSBIND_METHOD(observe_property, "observeProperty");
}

JSBIND_ADDON(mpv_wrapper)
