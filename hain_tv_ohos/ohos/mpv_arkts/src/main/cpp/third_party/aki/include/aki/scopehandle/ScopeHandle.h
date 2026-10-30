/*
 * Copyright (C) 2022 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef AKI_SCOPEHANDLE_H
#define AKI_SCOPEHANDLE_H
#include <node_api.h>
#include "aki/jsbind.h"
namespace aki {

class ScopeHandle {
public:
    ScopeHandle(napi_env env, bool enableEscapable) : env_(env)
    {
        napi_status status;
        if (env_ == nullptr) {
            AKI_LOG(ERROR) << "env_ is null!";
            return;
        }
        
        if (enableEscapable) {
            status = napi_open_escapable_handle_scope(env, &escapableHandle_);
        } else {
            status = napi_open_handle_scope(env, &scopeHandle_);
        }
        if (status != napi_ok) {
            AKI_LOG(ERROR) << "open cope handle failed! errcode = " << status;
        }
    }

    napi_status EscapeHandle(napi_value escapedObj, napi_value *result)
    {
        if (env_ == nullptr || escapableHandle_ == nullptr) {
            AKI_LOG(ERROR) << "env_ or escapableHandle_ is NULL!";
            return napi_invalid_arg;
        }
        return napi_escape_handle(env_, escapableHandle_, escapedObj, result);
    }

    ~ScopeHandle()
    {
        if (env_ == nullptr) {
            AKI_LOG(ERROR) << "env_ is null!";
            return;
        }
        if (scopeHandle_ != nullptr) {
            napi_close_handle_scope(env_, scopeHandle_);
        }
        if (escapableHandle_ != nullptr) {
            napi_close_escapable_handle_scope(env_, escapableHandle_);
        }
    }
private:
    napi_handle_scope scopeHandle_ = nullptr;
    napi_escapable_handle_scope escapableHandle_ = nullptr;
    napi_env env_ = nullptr;
};
} // namespace aki
#endif // AKI_SCOPEHANDLE_H
