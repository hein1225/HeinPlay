/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 */

#include <hilog/log.h>

#include "log.h"

void log_e(const char* msg)
{
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0250, "mpv", "%{public}s", msg);
}

void log_i(const char* msg)
{
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0250, "mpv", "%{public}s", msg);
}

void log_w(const char* msg)
{
    OH_LOG_Print(LOG_APP, LOG_WARN, 0x0250, "mpv", "%{public}s", msg);
}

void log_f(const char* msg)
{
    OH_LOG_Print(LOG_APP, LOG_FATAL, 0x0250, "mpv", "%{public}s", msg);
}
