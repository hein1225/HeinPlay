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

#ifndef AKI_ASYNCWORKER_H
#define AKI_ASYNCWORKER_H

#include <js_native_api.h>
#include <node_api.h>
#include <node_api_types.h>
#include "aki/config.h"

#ifdef __OHOS__
#include <napi/native_api.h>
#endif

namespace aki {

class AKI_EXPORT AsyncWorker {
public:
    class AsyncData {
        public:
        napi_deferred deferred_ = nullptr;
        void* data = nullptr;
    };

    ~AsyncWorker();
    AsyncWorker();
    AsyncWorker(napi_async_execute_callback execute, napi_async_complete_callback complete, void* data);

    int SetData(void* data);
    int SetExecuteCallback(napi_async_execute_callback execute);
    int SetCompleteCallback(napi_async_complete_callback complete);
    napi_value CreateAsyncWorker(const char *resource_name = "default");

    bool Queue();

private:
    class InnerAsyncData : public AsyncData {
    public:
        napi_async_work worker_ = nullptr;
        napi_async_execute_callback execute_ = nullptr;
        napi_async_complete_callback complete_ = nullptr;
    };
    
    static void ExecuteCallback(napi_env env, void* data);
    static void CompleteCallback(napi_env env, napi_status status, void* data);

    InnerAsyncData *asyncData_;
    napi_env env_;
};

}

#endif
