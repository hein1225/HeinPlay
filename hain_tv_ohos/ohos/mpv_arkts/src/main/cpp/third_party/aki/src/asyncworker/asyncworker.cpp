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

#include "aki/asyncworker/asyncworker.h"
#include "aki/binding.h"
#include "aki/logging/logging.h"

namespace aki {

AsyncWorker::~AsyncWorker()
{
}

AsyncWorker::AsyncWorker()
{
    env_ = aki::Binding::GetScopedEnv();
    asyncData_ = nullptr;
}

AsyncWorker::AsyncWorker(napi_async_execute_callback execute,
                         napi_async_complete_callback complete, void* data) : AsyncWorker()
{
    SetExecuteCallback(execute);
    SetCompleteCallback(complete);
    SetData(data);
}

int AsyncWorker::SetData(void* data)
{
    if (asyncData_ == nullptr) {
        asyncData_ = new InnerAsyncData;
    }

    if (asyncData_ == nullptr) {
        return -1;
    }

    asyncData_->data = data;
    return 0;
}

int AsyncWorker::SetExecuteCallback(napi_async_execute_callback execute)
{
    if (asyncData_ == nullptr) {
        asyncData_ = new InnerAsyncData;
    }

    if (asyncData_ == nullptr) {
        return -1;
    }

    asyncData_->execute_ = execute;
    return 0;
}

int AsyncWorker::SetCompleteCallback(napi_async_complete_callback complete)
{
    if (asyncData_ == nullptr) {
        asyncData_ = new InnerAsyncData;
    }

    if (asyncData_ == nullptr) {
        return -1;
    }

    asyncData_->complete_ = complete;
    return 0;
}

napi_value AsyncWorker::CreateAsyncWorker(const char *resource_name)
{
    if (asyncData_ == nullptr) {
        asyncData_ = new InnerAsyncData;
    }

    napi_value promise;
    napi_status status = napi_create_promise(env_, &asyncData_->deferred_, &promise);
    AKI_DCHECK(status == napi_ok);

    napi_value resourceId;
    status = napi_create_string_utf8(env_, resource_name, NAPI_AUTO_LENGTH, &resourceId);
    AKI_DCHECK(status == napi_ok);

    status = napi_create_async_work(env_,
                                    nullptr,
                                    resourceId,
                                    ExecuteCallback,
                                    CompleteCallback,
                                    asyncData_,
                                    &asyncData_->worker_);
    AKI_DCHECK(status == napi_ok);

    return promise;
}

bool AsyncWorker::Queue()
{
    if (asyncData_ == nullptr || asyncData_->worker_ == nullptr) {
        return false;
    }

    napi_status status = napi_queue_async_work(env_, asyncData_->worker_);
    AKI_DCHECK(status == napi_ok);
    return true;
}

void AsyncWorker::ExecuteCallback(napi_env env, void* data)
{
    InnerAsyncData *asyncData = reinterpret_cast<InnerAsyncData *>(data);
    if (asyncData->execute_ != nullptr) {
        asyncData->execute_(env, data);
    }
}

void AsyncWorker::CompleteCallback(napi_env env, napi_status status, void* data)
{
    InnerAsyncData *asyncData = reinterpret_cast<InnerAsyncData *>(data);
    if (asyncData->complete_ != nullptr) {
        asyncData->complete_(env, status, data);
    }

    if (asyncData != nullptr) {
        napi_delete_async_work(env, asyncData->worker_);
        delete asyncData;
    }
}
}
