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

#ifndef AKI_NAPI_VALUE_TRAIT_H
#define AKI_NAPI_VALUE_TRAIT_H

#include <js_native_api.h>
#include <node_api.h>

#include "aki/value/napi/napi_value.h"
#include "aki/logging/logging.h"
#include "aki/binding.h"
#include "aki/scopehandle/ScopeHandle.h"

namespace aki {

template<typename T>
class NapiValueMaker : public NapiValue<typename DetectPolicies<T>::Type> {
public:
    using NapiValue<typename DetectPolicies<T>::Type>::NapiValue;

    ~NapiValueMaker()
    {
    }
};

/**
 * @brief: NapiValueTrait::Cast 使用模板类函数，因为模板函数无法自动推导返回值
 */
#if USING_CXX_STANDARD_11
template<typename T>
struct NapiValueTrait {
    static T CastFunction(internal::Value& value, std::true_type)
    {
        NapiValue<T>& alphaValue = *(static_cast<NapiValue<T>*>(&value));
        return alphaValue.GetEnumeration();
    }

    static T CastFunction(internal::Value& value, std::false_type)
    {
        return static_cast<T&>(value);
    }

    static T Cast(internal::Value& value)
    {
        return CastFunction(value, std::is_enum<T>());
    }
};
#else
template<typename T>
struct NapiValueTrait {
    static T Cast(internal::Value& value)
    {
        if constexpr (std::is_enum<T>::value) {
            NapiValue<T>& alphaValue = *(static_cast<NapiValue<T>*>(&value));
            return alphaValue.GetEnumeration();
        } else {
            return static_cast<T&>(value);
        }
    }
};
#endif

template<typename T>
struct NapiValueTrait<T&> {
    static T& Cast(internal::Value& value)
    {
        return static_cast<T&>(value);
    }
};

template<typename T>
struct NapiValueTrait<T*> {
    static T* Cast(internal::Value& value)
    {
        return static_cast<T*>(value);
    }
};

template<typename T>
struct NapiValueTrait<Equivalence<T>> {
    static T Cast(internal::Value& value)
    {
        return static_cast<T&>(value);
    }
};

template<>
struct NapiValueTrait<bool> {
    static bool Cast(internal::Value& value)
    {
        return static_cast<bool>(value);
    }
};

template<>
struct NapiValueTrait<uint8_t> {
    static uint8_t Cast(internal::Value& value)
    {
        return static_cast<uint8_t>(value);
    }
};

template<>
struct NapiValueTrait<int8_t> {
    static int8_t Cast(internal::Value& value)
    {
        return static_cast<int8_t>(value);
    }
};

template<>
struct NapiValueTrait<uint16_t> {
    static uint16_t Cast(internal::Value& value)
    {
        return static_cast<uint16_t>(value);
    }
};

template<>
struct NapiValueTrait<int16_t> {
    static int16_t Cast(internal::Value& value)
    {
        return static_cast<int16_t>(value);
    }
};

template<>
struct NapiValueTrait<int> {
    static int Cast(internal::Value& value)
    {
        return static_cast<int>(value);
    }
};

template<>
struct NapiValueTrait<uint32_t> {
    static uint32_t Cast(internal::Value& value)
    {
        return static_cast<uint32_t>(value);
    }
};

template<>
struct NapiValueTrait<uint64_t> {
    static uint64_t Cast(internal::Value& value)
    {
        return static_cast<uint64_t>(value);
    }
};

template<>
struct NapiValueTrait<int64_t> {
    static int64_t Cast(internal::Value& value)
    {
        return static_cast<int64_t>(value);
    }
};

template<>
struct NapiValueTrait<double> {
    static double Cast(internal::Value& value)
    {
        return static_cast<double>(value);
    }
};

template<>
struct NapiValueTrait<float> {
    static float Cast(internal::Value& value)
    {
        return static_cast<float>(value);
    }
};

template<>
struct NapiValueTrait<std::string> {
    static std::string Cast(internal::Value& value)
    {
#if USING_CXX_STANDARD_11
        return static_cast<std::string>(value.GetString());
#else
        return static_cast<std::string>(value);
#endif
    }
};

template<>
struct NapiValueTrait<const std::string&> {
    static std::string Cast(internal::Value& value)
    {
#if USING_CXX_STANDARD_11
        return static_cast<std::string>(value.GetString());
#else
        return static_cast<std::string>(value);
#endif
    }
};

template<typename T>
struct NapiValueTrait<std::shared_ptr<T>> {
    static std::shared_ptr<T> Cast(internal::Value& value)
    {
        return value.SharedReference<T>();
    }
};

template<typename R, typename... P>
struct NapiValueTrait<std::function<R (P...)>> {
    static std::function<R (P...)> Cast(internal::Value& value)
    {
        return value.FunctionReference<R, P...>();
    }
};

template<typename R, typename... P>
struct NapiValueTrait<Callback<R (P...)>> {
    static Callback<R (P...)> Cast(internal::Value& value)
    {
        NapiValue<Callback<R (P...)>>& alphaValue = *(static_cast<NapiValue<Callback<R (P...)>>*>(&value));
        return alphaValue.GetFunction();
    }
};

template<typename R, typename... P>
struct NapiValueTrait<SafetyCallback<R (P...)>> {
    static SafetyCallback<R (P...)> Cast(internal::Value& value)
    {
        NapiValue<SafetyCallback<R (P...)>>& alphaValue = *(static_cast<NapiValue<SafetyCallback<R (P...)>>*>(&value));
        return alphaValue.GetFunction();
    }
};

template<>
struct NapiValueTrait<ArrayBuffer> {
    static ArrayBuffer Cast(internal::Value& value)
    {
#if USING_CXX_STANDARD_11
        return static_cast<ArrayBuffer>(value.GetArrayBuffer());
#else
        return static_cast<ArrayBuffer>(value);
#endif
    }
};

template<>
struct NapiValueTrait<Promise> {
    static Promise Cast(internal::Value& value)
    {
#if USING_CXX_STANDARD_11
        return static_cast<Promise>(value.GetPromise());
#else
        return static_cast<Promise>(value);
#endif
    }
};

template<typename K, typename T>
struct NapiValueTrait<std::map<K, T>> {
    static std::map<K, T> Cast(internal::Value& value)
    {
        return value.MapReference<K, T>();
    }
};

template<typename K, typename T>
struct NapiValueTrait<std::unordered_map<K, T>> {
    static std::unordered_map<K, T> Cast(internal::Value& value)
    {
        return value.HashMapReference<K, T>();
    }
};

template<typename K, typename T>
struct NapiValueTrait<std::unordered_set<K, T>> {
    static std::unordered_set<K, T> Cast(internal::Value& value)
    {
        return value.HashSetReference<K, T>();
    }
};

template<typename T>
struct NapiValueTrait<std::vector<T>> {
    static std::vector<T> Cast(internal::Value& value)
    {
        return value.VectorReference<T>();
    }
};

template<typename T, std::size_t N>
struct NapiValueTrait<std::array<T, N>> {
    static std::array<T, N> Cast(internal::Value& value)
    {
        return value.ArrayReference<T, N>();
    }
};

template<>
struct NapiValueTrait<JSFunction> {
    static JSFunction Cast(internal::Value& value)
    {
        NapiValue<JSFunction>& alphaValue = *(static_cast<NapiValue<JSFunction>*>(&value));
        return alphaValue.GetJSFunction();
    }
};

template<>
struct NapiValueTrait<napi_value> {
    static napi_value Cast(internal::Value& value)
    {
        NapiValue<napi_value>& alphaValue = *(static_cast<NapiValue<napi_value>*>(&value));
        return alphaValue.GetNapiValue();
    }
};

template<>
struct NapiValueTrait<Value> {
    static Value Cast(internal::Value& value)
    {
        NapiValue<napi_value>& alphaValue = *(static_cast<NapiValue<napi_value>*>(&value));
        return Value(alphaValue.GetNapiValue());
    }
};

#ifndef USING_CXX_STANDARD_11

template<typename T>
struct NapiValueTrait<std::optional<T>> {
    static std::optional<T> Cast(internal::Value& value)
    {
        return value.OptionalReference<T>();
    }
};

template<typename T>
std::optional<T> NapiValue<std::optional<T>>::GetOptional()
{
    napi_status status;
    napi_valuetype type;
    status = napi_typeof(env_, value_, &type);
    AKI_DCHECK(status == napi_ok);
    if (type == napi_undefined) {
        return {};
    }

    auto napiValue = NapiValue<typename ValueDefiner<T>::RawType>(env_, value_);
    T t = NapiValueTrait<typename ValueDefiner<T>::RawType>::Cast(napiValue);

    return std::optional<T>(t);
}

#endif

// NapiValue<std::vector<T>>
template<typename T>
std::vector<T> NapiValue<std::vector<T>>::GetVector()
{
    napi_status status;
    napi_env env = env_;
    std::vector<T> result;
    uint32_t length;
    status = napi_get_array_length(env, value_, &length);
    AKI_DCHECK(status == napi_ok);
    for (uint32_t i = 0; i < length; i++) {
        napi_value element;
        status = napi_get_element(env, value_, i, &element);
        AKI_DCHECK(status == napi_ok);
        auto napiValue = NapiValue<typename ValueDefiner<T>::RawType>(env, element);
        T t = NapiValueTrait<typename ValueDefiner<T>::RawType>::Cast(napiValue);
        result.push_back(t);
    }

    return result;
}
// std::array
template<typename T, size_t N>
std::array<T, N> NapiValue<std::array<T, N>>::GetArray()
{
    napi_status status;
    napi_env env = env_;
    std::array<T, N> result;
    uint32_t length;
    status = napi_get_array_length(env, value_, &length);
    AKI_DCHECK(status == napi_ok);
    for (uint32_t i = 0; i < length; i++) {
        napi_value element;
        status = napi_get_element(env, value_, i, &element);
        AKI_DCHECK(status == napi_ok);
        auto napiValue = NapiValueMaker<T>(env, element);
        T t = ValueTrait<typename ValueDefiner<T>::RawType>::Cast(napiValue);
        result[i] = std::move(t);
    }

    return result;
}

#if USING_CXX_STANDARD_11
template<typename K>
static bool GetAkiObjectKey(napi_value& keyNapi, K& key, std::true_type)
{
    key = aki::Value(keyNapi);
    return true;
}
template<typename K>
static bool GetAkiObjectKey(napi_value& keyNapi, K& key, std::false_type)
{
    AKI_LOG(ERROR) << "Unsupported key type for conversion!";
    return false;
}
template<typename K>
static bool GetConstCharObjectKey(napi_value& keyNapi, std::string& keyStr, K& key, std::true_type)
{
    key = keyStr.c_str();
    return true;
}
template<typename K>
static bool GetConstCharObjectKey(napi_value& keyNapi, std::string& keyStr, K& key, std::false_type)
{
    return GetAkiObjectKey(keyNapi, key, std::is_same<K, aki::Value>());
}
template<typename K>
static bool GetCharObjectKey(napi_value& keyNapi, std::string& keyStr, K& key, std::true_type)
{
    key = keyStr.c_str();
    return true;
}
template<typename K>
static bool GetCharObjectKey(napi_value& keyNapi, std::string& keyStr, K& key, std::false_type)
{
    return GetConstCharObjectKey(keyNapi, keyStr, key, std::is_same<K, const char*>());
}
template<typename K>
static bool GetStrObjectKey(napi_value& keyNapi, std::string& keyStr, K& key, std::true_type)
{
    key = keyStr;
    return true;
}
template<typename K>
static bool GetStrObjectKey(napi_value& keyNapi, std::string& keyStr, K& key, std::false_type)
{
    return GetCharObjectKey(keyNapi, keyStr, key, std::is_same<K, char*>());
}
template<typename K>
static bool GetNumObjectKey(napi_value& keyNapi, std::string& keyStr, K& key, std::true_type)
{
    if (!aki::Value::StringToNumber(keyStr, key)) {
        AKI_LOG(ERROR) << "StringToNumber failed";
        return false;
    }
    return true;
}
template<typename K>
static bool GetNumObjectKey(napi_value& keyNapi, std::string& keyStr, K& key, std::false_type)
{
    return GetStrObjectKey(keyNapi, keyStr, key, std::is_same<K, std::string>());
}
#endif
template<typename K>
static bool GetObjectKey(napi_env& env, napi_value& keyNapi, K& key)
{
    NapiValue<std::string> keyNapiValue(env, keyNapi);
    std::string keyStr = keyNapiValue.GetString();
#if USING_CXX_STANDARD_11
    return GetNumObjectKey(keyNapi, keyStr, key, std::is_arithmetic<K>());
#else
    if constexpr (std::is_arithmetic<K>::value) {
        if (!aki::Value::StringToNumber(keyStr, key)) {
            AKI_LOG(ERROR) << "StringToNumber failed";
            return false;
        }
    } else if constexpr (std::is_same<K, std::string>::value) {
        key = keyStr;
    } else if constexpr (std::is_same<K, char*>::value || std::is_same<K, const char*>::value) {
        key = keyStr.c_str();
    } else if constexpr (std::is_same<K, aki::Value>::value) {
        key = aki::Value(keyNapi);
    } else {
        AKI_LOG(ERROR) << "Unsupported key type for conversion!";
        return false;
    }

    return true;
#endif
}

template<typename K, typename T>
void NapiValue<std::map<K, T>>::GetMapInfo()
{
    napi_env env = env_;
    napi_valuetype type;
    napi_value forEachFunc;
    napi_status status = napi_get_named_property(env, value_, "forEach", &forEachFunc);
    napi_typeof(env, forEachFunc, &type);
    if (type == napi_function) {
        auto forEachCallback = [](napi_env env, napi_callback_info info) -> napi_value {
            size_t argc = 2;
            napi_value argv[argc];

            NapiValue *napiValue;
            napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, (void **)&napiValue);
            AKI_DCHECK(status == napi_ok);

            auto keyNapi = NapiValue<typename ValueDefiner<K>::RawType>(env, argv[1]);
            K k = NapiValueTrait<typename ValueDefiner<K>::RawType>::Cast(keyNapi);

            auto valueNapi = NapiValue<typename ValueDefiner<T>::RawType>(env, argv[0]);
            T t = NapiValueTrait<typename ValueDefiner<T>::RawType>::Cast(valueNapi);

            napiValue->obj_[k] = t;

            return nullptr;
        };

        napi_value fn;
        status = napi_create_function(env, "callback", NAPI_AUTO_LENGTH, forEachCallback, this, &fn);
        AKI_DCHECK(status == napi_ok);

        napi_value return_val;
        status = napi_call_function(env, value_, forEachFunc, 1, &fn, &return_val);
        AKI_DCHECK(status == napi_ok);
    }
}

template<typename K, typename T>
void NapiValue<std::map<K, T>>::GetMapObject()
{
    napi_status status;
    napi_env env = env_;
    napi_value names;
    status = napi_get_property_names(env, value_, &names);
    AKI_DCHECK(status == napi_ok);

    uint32_t length;
    status = napi_get_array_length(env, names, &length);
    AKI_DCHECK(status == napi_ok);

    for (auto index = 0; index < length; index++) {
        napi_value keyNapi;
        status = napi_get_element(env, names, index, &keyNapi);
        AKI_DCHECK(status == napi_ok);

        K k;
        bool result = GetObjectKey(env, keyNapi, k);
        AKI_DCHECK(result);
        napi_value valueNapi;
        status = napi_get_property(env, value_, keyNapi, &valueNapi);
        AKI_DCHECK(status == napi_ok);
        auto valueNapiValue = NapiValueMaker<T>(env, valueNapi);
        T t = NapiValueTrait<typename ValueDefiner<T>::RawType>::Cast(valueNapiValue);
        obj_[k] = t;
    }

    GetMapInfo();
}

template<typename K, typename T, typename H>
void NapiValue<std::unordered_map<K, T, H>>::GetHashMapInfo()
{
    napi_env env = env_;
    napi_valuetype type;
    napi_value forEachFunc;
    napi_status status = napi_get_named_property(env, value_, "forEach", &forEachFunc);
    napi_typeof(env, forEachFunc, &type);
    if (type == napi_function) {
        auto forEachCallback = [](napi_env env, napi_callback_info info) -> napi_value {
            size_t argc = 2;
            napi_value argv[argc];

            NapiValue *napiValue;
            napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, (void **)&napiValue);
            AKI_DCHECK(status == napi_ok);

            auto keyNapi = NapiValue<typename ValueDefiner<K>::RawType>(env, argv[1]);
            K k = NapiValueTrait<typename ValueDefiner<K>::RawType>::Cast(keyNapi);

            auto valueNapi = NapiValue<typename ValueDefiner<T>::RawType>(env, argv[0]);
            T t = NapiValueTrait<typename ValueDefiner<T>::RawType>::Cast(valueNapi);

            napiValue->obj_[k] = t;
            return nullptr;
        };

        napi_value fn;
        status = napi_create_function(env, "callback", NAPI_AUTO_LENGTH, forEachCallback, this, &fn);
        AKI_DCHECK(status == napi_ok);

        napi_value return_val;
        status = napi_call_function(env, value_, forEachFunc, 1, &fn, &return_val);
        AKI_DCHECK(status == napi_ok);
    }
}

template<typename K, typename T, typename H>
void NapiValue<std::unordered_map<K, T, H>>::GetHashMapObject()
{
    napi_status status;
    napi_env env = env_;
    napi_value names;

    status = napi_get_property_names(env, value_, &names);
    AKI_DCHECK(status == napi_ok);

    uint32_t length;
    status = napi_get_array_length(env, names, &length);
    AKI_DCHECK(status == napi_ok);

    for (auto index = 0; index < length; index++) {
        napi_value keyNapi;
        status = napi_get_element(env, names, index, &keyNapi);
        AKI_DCHECK(status == napi_ok);

        K k;
        bool result = GetObjectKey(env, keyNapi, k);
        AKI_DCHECK(result);

        napi_value valueNapi;
        status = napi_get_property(env, value_, keyNapi, &valueNapi);
        AKI_DCHECK(status == napi_ok);
        auto valueNapiValue = NapiValueMaker<T>(env, valueNapi);
        T t = NapiValueTrait<typename ValueDefiner<T>::RawType>::Cast(valueNapiValue);
        obj_[k] = t;
    }

    GetHashMapInfo();
}

template<typename T, typename H>
void NapiValue<std::unordered_set<T, H>>::GetHashSetInfo()
{
    napi_env env = env_;
    napi_valuetype type;
    napi_value forEachFunc;
    napi_status status = napi_get_named_property(env, value_, "forEach", &forEachFunc);
    napi_typeof(env, forEachFunc, &type);
    if (type == napi_function) {
        auto forEachCallback = [](napi_env env, napi_callback_info info) -> napi_value {
            size_t argc = 1;
            napi_value argv[argc];

            NapiValue *napiValue;
            napi_status status = napi_get_cb_info(env, info, &argc, argv, nullptr, (void **)&napiValue);
            AKI_DCHECK(status == napi_ok);

            auto valueNapi = NapiValue<typename ValueDefiner<T>::RawType>(env, argv[0]);
            T t = NapiValueTrait<typename ValueDefiner<T>::RawType>::Cast(valueNapi);

            napiValue->obj_.insert(t);
            return nullptr;
        };

        napi_value fn;
        status = napi_create_function(env, "callback", NAPI_AUTO_LENGTH, forEachCallback, this, &fn);
        AKI_DCHECK(status == napi_ok);

        napi_value return_val;
        status = napi_call_function(env, value_, forEachFunc, 1, &fn, &return_val);
        AKI_DCHECK(status == napi_ok);
    }
}

template<typename T, typename H>
void NapiValue<std::unordered_set<T, H>>::GetHashSetObject()
{
    napi_status status;
    napi_env env = env_;
    bool isArray;
    status = napi_is_array(env, value_, &isArray);
    AKI_DCHECK(status == napi_ok);

    if (isArray) {
        uint32_t length;
        status = napi_get_array_length(env, value_, &length);
        AKI_DCHECK(status == napi_ok);

        for (uint32_t i = 0; i < length; i++) {
            napi_value element;
            status = napi_get_element(env, value_, i, &element);
            AKI_DCHECK(status == napi_ok);

            auto napiValue = NapiValue<typename ValueDefiner<T>::RawType>(env, element);
            T t = NapiValueTrait<typename ValueDefiner<T>::RawType>::Cast(napiValue);
            obj_.insert(t);
        }
    }

    GetHashSetInfo();
}

#if USING_CXX_STANDARD_11
template<typename R, typename... P>
template<typename... Args>
void Callback<R (P...)>::CallFunction(napi_env env, napi_value result, std::true_type, std::false_type) const
{
    return;
}

template<typename R, typename... P>
template<typename... Args>
napi_value Callback<R (P...)>::CallFunction(napi_env env, napi_value result, std::false_type, std::true_type) const
{
    return result;
}

template<typename R, typename... P>
template<typename... Args>
R Callback<R (P...)>::CallFunction(napi_env env, napi_value result, std::false_type, std::false_type) const
{
    AKI_CHECK(NapiValue<R>::CheckType(env, result)) << "should return type with: " << NapiValue<R>::ExpectedType();
    auto napiValue = NapiValueMaker<R>(env, result);
    return NapiValueTrait<R>::Cast(napiValue);
}
#endif

template<typename R, typename... P>
template<typename... Args>
R Callback<R (P...)>::Call(Args&&... args) const
{
    napi_value result = nullptr;
    napi_status status;
    napi_env env = env_;
    napi_value cb = cb_;
    size_t argc = sizeof...(P);

    ScopeHandle *scopeHandle = new ScopeHandle(env, true);
    AKI_DCHECK(scopeHandle != nullptr) << "scopeHandle is NULL";
    std::array<napi_value, sizeof...(P)> argv =
        {NapiValue<typename ValueDefiner<Args>::RawType>::ToNapiValue(env, std::forward<Args>(args))...};
    napi_value escapedObj;
    napi_value undefined;
    status = napi_get_undefined(env, &undefined);
    AKI_DCHECK(status == napi_ok) << "napi_get_undefined status: " << status;
    status = napi_call_function(env, undefined, cb, argc, argv.data(), &escapedObj);
    AKI_DCHECK(status == napi_ok) << "napi_call_function status: " << status;
    status = scopeHandle->EscapeHandle(escapedObj, &result);
    AKI_DCHECK(status == napi_ok) << "EscapeHandle status: " << status;
    delete scopeHandle;
    scopeHandle = nullptr;
    // add exception obtain from napi function
    bool isExceptionPending = false;
    napi_status exceptionStatus = napi_is_exception_pending(env, &isExceptionPending);
    AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;

    if (isExceptionPending) {
        napi_value result;
        exceptionStatus = napi_get_and_clear_last_exception(env, &result);
        AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;
        napi_value errorString;
        exceptionStatus = napi_coerce_to_string(env, result, &errorString);
        AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;
        size_t length = 0;
        exceptionStatus = napi_get_value_string_utf8(env, errorString, nullptr, 0, &length);
        AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;
        std::string buf(length+1, '\0');
#if USING_CXX_STANDARD_11
        exceptionStatus = napi_get_value_string_utf8(env, errorString, (char*)buf.data(), length+1, &length);
#else
        exceptionStatus = napi_get_value_string_utf8(env, errorString, buf.data(), length+1, &length);
#endif
        AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;
        AKI_DLOG(DEBUG) << "napi_call_function failed, errorMessage: " << buf;
        AKI_DCHECK(false) << "napi_call_function failed, errorMessage: " << buf;
    }

    AKI_DCHECK(status == napi_ok) << "status: " << status;

#if USING_CXX_STANDARD_11
    return CallFunction(env, result, std::is_void<R>(), std::is_same<R, napi_value>());
#else
    if constexpr (std::is_void<R>::value) {
        return;
    } else if constexpr (std::is_same<R, napi_value>::value) {
        return result;
    } else {
        AKI_CHECK(NapiValue<R>::CheckType(env, result)) << "should return type with: " << NapiValue<R>::ExpectedType();
        auto napiValue = NapiValueMaker<R>(env, result);
        return NapiValueTrait<R>::Cast(napiValue);
    }
#endif
}

#if USING_CXX_STANDARD_11
template<typename R, typename... P>
template<typename... Args>
void Callback<R (P...)>::CallMethodFunction(napi_env env, napi_value result, std::true_type, std::false_type) const
{
    return;
}

template<typename R, typename... P>
template<typename... Args>
napi_value Callback<R (P...)>::CallMethodFunction(napi_env env, napi_value result,
    std::false_type, std::true_type) const
{
    return result;
}

template<typename R, typename... P>
template<typename... Args>
R Callback<R (P...)>::CallMethodFunction(napi_env env, napi_value result, std::false_type, std::false_type) const
{
    AKI_CHECK(NapiValue<R>::CheckType(env, result)) << "should return type with: " << NapiValue<R>::ExpectedType();
    auto napiValue = NapiValueMaker<R>(env, result);
    return NapiValueTrait<R>::Cast(napiValue);
}
#endif

template<typename R, typename... P>
template<typename... Args>
R Callback<R (P...)>::CallMethod(napi_env env, napi_value recv, Args&&... args) const
{
    ScopeHandle *scopeHandle = new ScopeHandle(env, true);
    AKI_DCHECK(scopeHandle != nullptr) << "scopeHandle is NULL";
    size_t argc = sizeof...(P);
    std::array<napi_value, sizeof...(P)> argv =
        {NapiValue<typename ValueDefiner<Args>::RawType>::ToNapiValue(env, std::forward<Args>(args))...};

    napi_value result = nullptr;
    napi_value escapedObj = nullptr;
    napi_status status = napi_call_function(env, recv, cb_, argc, argv.data(), &escapedObj);
    AKI_DCHECK(status == napi_ok) << "napi_call_function status: " << status;
    status = scopeHandle->EscapeHandle(escapedObj, &result);
    AKI_DCHECK(status == napi_ok) << "EscapeHandle status: " << status;
    delete scopeHandle;
    scopeHandle = nullptr;
    // add exception obtain from napi function
    bool isExceptionPending = false;
    napi_status exceptionStatus = napi_is_exception_pending(env, &isExceptionPending);
    AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;

    if (isExceptionPending) {
        napi_value result;
        exceptionStatus = napi_get_and_clear_last_exception(env, &result);
        AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;
        napi_value errorString;
        exceptionStatus = napi_coerce_to_string(env, result, &errorString);
        AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;
        size_t length = 0;
        exceptionStatus = napi_get_value_string_utf8(env, errorString, nullptr, 0, &length);
        AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;
        std::string buf(length+1, '\0');
#if USING_CXX_STANDARD_11
        exceptionStatus = napi_get_value_string_utf8(env, errorString, (char*)buf.data(), length+1, &length);
#else
        exceptionStatus = napi_get_value_string_utf8(env, errorString, buf.data(), length+1, &length);
#endif
        AKI_DCHECK(exceptionStatus == napi_ok) << "exceptionStatus: " << exceptionStatus;
        AKI_LOG(DEBUG) << "napi_call_function failed, errorMessage: " << buf;
    }

    AKI_DCHECK(status == napi_ok) << "status: " << status;

#if USING_CXX_STANDARD_11
    return CallMethodFunction(env, result, std::is_void<R>(), std::is_same<R, napi_value>());
#else
    if constexpr (std::is_void<R>::value) {
        return;
    } else if constexpr (std::is_same<R, napi_value>::value) {
        return result;
    } else {
        AKI_CHECK(NapiValue<R>::CheckType(env, result)) << "should return type with: " << NapiValue<R>::ExpectedType();
        auto napiValue = NapiValueMaker<R>(env, result);
        return NapiValueTrait<R>::Cast(napiValue);
    }
#endif
}

template<typename R, typename... P>
template<size_t... Index>
napi_value NapiCallbackBinder<R, P...>::SafetyWrapper(napi_env& env,
    napi_callback_info info, std::index_sequence<Index...>)
{
    AKI_DLOG(DEBUG) << "NapiCallbackBinder::SafetyWrapper";
    napi_status status;
    void* invoker = nullptr;
    size_t argc = sizeof...(Index);
    std::array<napi_value, sizeof...(Index)> args;

    status = napi_get_cb_info(env, info, &argc, args.data(), nullptr, &invoker);
    AKI_DCHECK(status == napi_ok);
    AKI_DCHECK(invoker != nullptr);
    auto tuple = std::make_tuple(NapiValueMaker<typename ValueDefiner<P>::RawType>(env, args[Index])...);
    auto valueTuple = std::make_tuple(
        NapiValueTrait<typename ValueDefiner<P>::RawType>::Cast(std::get<Index>(tuple))...);

#if USING_CXX_STANDARD_11
    return WrapperForward(env, invoker, std::is_void<R>(), std::get<Index>(valueTuple)...);
#else
    return WrapperForward(env, invoker, std::get<Index>(valueTuple)...);
#endif
}

#if USING_CXX_STANDARD_11
template<typename R, typename... P>
template<typename... Args>
napi_value NapiCallbackBinder<R, P...>::WrapperForward(napi_env& env, void* invoker, std::true_type, Args&&... args)
{
    AKI_DLOG(DEBUG) << "NapiCallbackBinder::WrapperForward";
    ParentType::InnerWrapper(reinterpret_cast<std::function<R (P...)>*>(invoker), std::forward<Args>(args)...);
    return nullptr;
}

template<typename R, typename... P>
template<typename... Args>
napi_value NapiCallbackBinder<R, P...>::WrapperForward(napi_env& env, void* invoker, std::false_type, Args&&... args)
{
    AKI_DLOG(DEBUG) << "NapiCallbackBinder::WrapperForward";
    R r = ParentType::InnerWrapper(reinterpret_cast<std::function<R (P...)>*>(invoker), std::forward<Args>(args)...);
    return NapiValue<R>::ToNapiValue(env, std::forward<R>(r));
}
#else
template<typename R, typename... P>
template<typename... Args>
napi_value NapiCallbackBinder<R, P...>::WrapperForward(napi_env& env, void* invoker, Args&&... args)
{
    AKI_DLOG(DEBUG) << "NapiCallbackBinder::WrapperForward";

    if constexpr (std::is_void<R>::value) {
        ParentType::InnerWrapper(reinterpret_cast<std::function<R (P...)>*>(invoker), std::forward<Args>(args)...);
        return nullptr;
    } else {
        R r = ParentType::InnerWrapper(
            reinterpret_cast<std::function<R (P...)>*>(invoker), std::forward<Args>(args)...);
        return NapiValue<R>::ToNapiValue(env, std::forward<R>(r));
    }
}
#endif

template<typename T>
Value::Value(T&& value)
{
    napi_env env = aki::Binding::GetScopedEnv();
    napi_value handle = NapiValue<T>::ToNapiValue(env, std::forward<T>(value));
    
    internal::Value* ival = new NapiValueMaker<napi_value>(env, handle);
    handle_.reset(ival);
    persistent_ = Persistent(handle);
}

template<typename T>
T Value::As() const
{
    return NapiValueTrait<T>::Cast(*handle_);
}

template<typename T>
T Value::ObjectAs() const
{
    napi_value value = persistent_.GetValue();
    internal::Value* val = new NapiValueMaker<aki::Value>(aki::Binding::GetScopedEnv(), value);
    return NapiValueTrait<T>::Cast(*val);
}

template<typename V>
void Value::Set(const char* key, const V& value)
{
    napi_status status;
    napi_env env = aki::Binding::GetScopedEnv();
    napi_value recv = persistent_.GetValue();

    napi_value nv = NapiValue<V>::ToNapiValue(env, value);
    status = napi_set_named_property(env, recv, key, nv);
    AKI_DCHECK(status == napi_ok);
}

template<typename V>
void Value::Set(const size_t index, V&& value)
{
    napi_status status;
    napi_env env = aki::Binding::GetScopedEnv();
    napi_value recv = persistent_.GetValue();

    napi_value nv = NapiValue<V>::ToNapiValue(env, value);
    status = napi_set_element(env, recv, index, nv);
    AKI_DCHECK(status == napi_ok);
}

template<typename... Args>
Value Value::operator()(Args&&... args) const
{
    Callback<napi_value (Args...)> jsCallback = NapiValueTrait<Callback<napi_value (Args...)>>::Cast(*handle_);
    return Value(jsCallback(std::forward<Args>(args)...));
}

template<typename... Args>
Value Value::CallMethod(const char* name, Args&&... args)
{
    napi_env env = aki::Binding::GetScopedEnv();
    napi_value recv = this->GetHandle();
    aki::Value funcV((*this)[name].GetHandle());
    Callback<napi_value (Args...)> jsCallback(env, funcV.GetHandle());
 
    return Value(jsCallback.CallMethod(env, recv, std::forward<Args>(args)...));
}

template<typename T>
static bool StringToInt(const std::string& str, T& value)
{
    char* endPtr = nullptr;
#if USING_CXX_STANDARD_11
    if (std::is_integral<T>::value) {
        const int DecimalBase = 10;
        if (sizeof(T) <= sizeof(int)) {
            if (std::is_signed<T>::value) {
#else
    if constexpr (std::is_integral_v<T>) {
        const int DecimalBase = 10;
        if constexpr (sizeof(T) <= sizeof(int)) {
            if constexpr (std::is_signed_v<T>) {
#endif
                value = std::strtol(str.c_str(), &endPtr, DecimalBase);
            } else {
                value = std::strtoul(str.c_str(), &endPtr, DecimalBase);
            }
        } else {
#if USING_CXX_STANDARD_11
            if (std::is_signed<T>::value) {
#else
            if constexpr (std::is_signed_v<T>) {
#endif
                value = std::strtoll(str.c_str(), &endPtr, DecimalBase);
            } else {
                value = std::strtoull(str.c_str(), &endPtr, DecimalBase);
            }
        }

#if USING_CXX_STANDARD_11
        if (*endPtr == str[0] || *endPtr != '\0' || (std::is_signed<T>::value ? (value < std::numeric_limits<T>::min()
            || value > std::numeric_limits<T>::max()) : (value < 0 || value > std::numeric_limits<T>::max()))) {
#else
        if (*endPtr == str[0] || *endPtr != '\0' || (std::is_signed_v<T> ? (value < std::numeric_limits<T>::min()
            || value > std::numeric_limits<T>::max()) : (value < 0 || value > std::numeric_limits<T>::max()))) {
#endif
            AKI_LOG(ERROR) << "Conversion failed: out of range or invalid input";
            return false;
        }
    }

    return true;
}

template<typename T>
bool Value::StringToNumber(const std::string& str, T& value)
{
    if (str.empty()) {
        AKI_LOG(ERROR) << "The parameter is invalid.";
        return false;
    }

    char* endPtr = nullptr;
    if (!StringToInt(str, value)) {
        return false;
    }
#if USING_CXX_STANDARD_11
    if (std::is_floating_point<T>::value) {
        if (std::is_same<T, float>::value) {
            value = std::strtof(str.c_str(), &endPtr);
        } else if (std::is_same<T, double>::value) {
#else
    if constexpr (std::is_floating_point_v<T>) {
        if constexpr (std::is_same_v<T, float>) {
            value = std::strtof(str.c_str(), &endPtr);
        } else if constexpr (std::is_same_v<T, double>) {
#endif
            value = std::strtod(str.c_str(), &endPtr);
        }

        if (*endPtr != '\0') {
            AKI_LOG(ERROR) << "Conversion failed: unable to convert string to floating point";
            return false;
        }
#if USING_CXX_STANDARD_11
    } else if (std::is_same<T, bool>::value) {
#else
    } else if constexpr (std::is_same<T, bool>::value) {
#endif
        value = str == "true" || str == "1";
    }

    return true;
}

template<typename T>
void Promise::Resolve(T&& t) const
{
    napi_env env = aki::Binding::GetScopedEnv();
    napi_value result = NapiValue<typename ValueDefiner<T>::RawType>::ToNapiValue(env, std::forward<T>(t));

    napi_resolve_deferred(env, deferred_, result);
}

template<typename T>
void Promise::Reject(T&& t) const
{
    napi_env env = aki::Binding::GetScopedEnv();
    napi_value result = NapiValue<typename ValueDefiner<T>::RawType>::ToNapiValue(env, std::forward<T>(t));

    napi_reject_deferred(env, deferred_, result);
}
} // namespace aki
#endif //AKI_NAPI_VALUE_TRAIT_H
