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

#ifndef AKI_SAFETY_CALLBACK_H
#define AKI_SAFETY_CALLBACK_H

#include <node_api.h>
#include <future>
#include <thread>

#include "aki/config.h"
#include "aki/callback/napi/callback.h"
#include "aki/logging/logging.h"

namespace aki {
struct ThreadSafeContext {
    template<typename R, typename... P>
    struct Data {
        std::tuple<typename ValueDefiner<P>::RawType...> params;

        std::shared_ptr<std::promise<R>> result;
    };

    ThreadSafeContext(const napi_env env,
                      const napi_value cb)
        : env(env), mainId_(std::this_thread::get_id())
    {
        napi_status status;
        napi_value workName;

        status = napi_create_string_utf8(env,
                                         "JSBind Thread-safe Call from Async Work Item",
                                         NAPI_AUTO_LENGTH,
                                         &workName);
        AKI_DCHECK(status == napi_ok) << "status: " << status;

        status = napi_create_reference(env,
                                       cb,
                                       1,
                                       &cbRef);
        AKI_DCHECK(status == napi_ok) << "status: " << status;

        status = napi_create_threadsafe_function(env,
                                                 cb,
                                                 nullptr,
                                                 workName,
                                                 0,
                                                 1,
                                                 cbRef,
                                                 FinalizeThreadsafeFunction,
                                                 this,
                                                 CallJs,
                                                 &(ts));
        AKI_DCHECK(status == napi_ok) << "status: " << status;
    }

    ~ThreadSafeContext()
    {
        napi_status status = napi_release_threadsafe_function(ts,
                                                              napi_tsfn_release);
        AKI_DCHECK(status == napi_ok) << "status: " << status;
    }

    template<typename R, typename... P>
    R Invoke(P&&... args) const
    {
        napi_status status;

        if (std::this_thread::get_id() == mainId_) {
            napi_value cb;
            AKI_DCHECK(cbRef != nullptr);
            status = napi_get_reference_value(env, cbRef, &cb);
            AKI_DCHECK(status == napi_ok) << "status: " << status;

            Callback<R (P...)> jsCallback(env, cb);
            return jsCallback(std::forward<P>(args)...);
        } else {
            // 因为在ForwardCallJs中固定进行 Data的资源回收，所以此处更改为使用new创建Data
            Data<R, P...> *data = new  Data<R, P...>({
                .params = std::make_tuple(std::forward<P>(args)...),
                .result = std::make_shared<std::promise<R>>()
            });
            
            // 在Invoke前 关联promise确保其生命周期
            auto future = data->result->get_future();
            Invoke(data);

            return future.get();
        }
    }

    void Invoke(void* data) const
    {
        napi_status status;

        status = napi_acquire_threadsafe_function(ts);
        AKI_DCHECK(status == napi_ok) << "status: " << status;
        AKI_DLOG(DEBUG) << "begin to call threadsafe function.";
        status = napi_call_threadsafe_function(ts,
                                               data,
                                               napi_tsfn_blocking);
        AKI_DCHECK(status == napi_ok) << "status: " << status;
        napi_release_threadsafe_function(ts, napi_tsfn_release);
    }

    template <typename R, typename... P>
    std::future<R> InvokeAsync(P &&...args) const
    {
        // data的内存 在ForwardCallJs中释放(data->result->set_value();完成之后)
        Data<R, P...> *data = new  Data<R, P...> ({
            .params = std::make_tuple(std::forward<P>(args)...), .result = std::make_shared<std::promise<R>>()});
        
        // 在Invoke前 关联promise确保其生命周期
        auto future = data->result->get_future();
        Invoke(data);
        return future;
    }

    const napi_env env;

    napi_ref cbRef = nullptr;

    napi_threadsafe_function ts = nullptr;

    std::thread::id mainId_;

    void (*forwardCallJs)(napi_env env, napi_value cb, void* data) = nullptr;

private:
    static void FinalizeThreadsafeFunction(napi_env env, void* raw, void* hint)
    {
        AKI_DLOG(DEBUG) << "FinalizeThreadsafeFunction";
        napi_ref cbRef = reinterpret_cast<napi_ref>(raw);
        napi_status status = napi_delete_reference(env, cbRef);
        AKI_DCHECK(status == napi_ok) << "status: " << status;
    }

    static void CallJs(napi_env env, napi_value noUsed, void* context, void* data)
    {
        AKI_DLOG(DEBUG) << "trigger threadsafe call js.";
        AKI_DCHECK(context != nullptr);
        napi_status status;
        ThreadSafeContext* ctx = (ThreadSafeContext*)(context);

        napi_value cb;
        AKI_DCHECK(ctx->cbRef != nullptr);
        status = napi_get_reference_value(env, ctx->cbRef, &cb);
        AKI_DCHECK(status == napi_ok) << "status: " << status;

        AKI_DCHECK(ctx->forwardCallJs != nullptr);
        return ctx->forwardCallJs(env, cb, data);
    }
};

template<typename T>
class SafetyCallback;

template<typename R, typename... P>
class SafetyCallback<R (P...)> {
public:
    explicit SafetyCallback(const napi_env env, const napi_value cb)
        : ctx_(std::make_shared<ThreadSafeContext>(env, cb))
    {
        ctx_->forwardCallJs = CallJs;
    }

    // 禁止调用方法时，阻塞JS线程，否则会导致进程挂死。
    R operator() (P... args) const
    {
        return(ctx_->template Invoke<R, P...>(std::move(args)...));
    }

    static void CallJs(napi_env env, napi_value cb, void* recvData)
    {
        AKI_DCHECK(env != nullptr);
        AKI_DCHECK(cb != nullptr);
        AKI_DCHECK(recvData != nullptr);

        ThreadSafeContext::Data<R, P...>* data = (ThreadSafeContext::Data<R, P...>*)recvData;
        return ForwardCallJs(env, cb, data, std::make_index_sequence<sizeof...(P)>());
    }

private:
#if USING_CXX_STANDARD_11
    template <size_t... I>
    static void ForwardCallJsHelper(napi_env env, napi_value cb, ThreadSafeContext::Data<R, P...>* data,
        std::false_type, std::index_sequence<I...>)
    {
        Callback<R (P...)> jsCallback(env, cb);
    
        R r = jsCallback(std::get<I>(data->params)...);
        data->result->set_value(r);
    }

    template <size_t... I>
    static void ForwardCallJsHelper(napi_env env, napi_value cb, ThreadSafeContext::Data<R, P...>* data,
        std::true_type, std::index_sequence<I...>)
    {
        Callback<R (P...)> jsCallback(env, cb);

        jsCallback(std::get<I>(data->params)...);
        data->result->set_value();
    }
#endif
    template<size_t... I>
    static void ForwardCallJs(napi_env env,
        napi_value cb,
        ThreadSafeContext::Data<R, P...>* data,
        std::index_sequence<I...>)
    {
        Callback<R (P...)> jsCallback(env, cb);

#if USING_CXX_STANDARD_11
        ForwardCallJsHelper(env, cb, data, std::is_void<R>(), std::make_index_sequence<sizeof...(P)>());
#else
        if constexpr(std::is_void<R>::value) {
            jsCallback(std::get<I>(data->params)...);
            data->result->set_value();
        } else {
            R r = jsCallback(std::get<I>(data->params)...);
            data->result->set_value(r);
        }
#endif

        // promise set_value结束 回收在Invoke/InvokeAsync 中创建的资源
        // data->result 不会立即销毁，而是在关联的std::future生命周期结束后自动释放
        delete data;

        return;
    }

    std::shared_ptr<ThreadSafeContext> ctx_;
};

} // namespace aki
#endif //AKI_SAFETY_CALLBACK_H
