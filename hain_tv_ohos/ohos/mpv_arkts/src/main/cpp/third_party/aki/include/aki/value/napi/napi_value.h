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

#ifndef AKI_NAPI_VALUE_H
#define AKI_NAPI_VALUE_H

#include <js_native_api.h>
#include <node_api.h>
#include <tuple>

#include "aki/binder/napi/napi_callback_binder.h"
#include "aki/value/napi/napi_value_base.h"
#include "aki/value/napi/js_function.h"
#include "aki/policy/policy.h"
#include "aki/class/class_wrapper.h"
#include "aki/callback/napi/callback.h"
#include "aki/callback/napi/safety_callback.h"
#include "aki/arg_storage/arg_storage.h"
#include "aki/overloader/napi/napi_overloader.h"
#include "aki/value/array_buffer.h"
#include "aki/value.h"

namespace aki {

// class base
class NapiObjectValue : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    static bool CheckType(napi_env env, napi_value value)
    {
        napi_status status;
        napi_valuetype type;
        status = napi_typeof(env, value, &type);
        AKI_DCHECK(status == napi_ok);
        return type == napi_object || type == napi_null;
    }

    static constexpr const char* ExpectedType()
    {
        return "object";
    }
};

template<typename T>
class NapiValue : public NapiObjectValue {
public:
    using NapiObjectValue::NapiObjectValue;

#if USING_CXX_STANDARD_11
    static napi_value ToNapiValueFunction(napi_env env, const T& arg, std::true_type)
    {
        napi_status status;
        napi_value enumValue;
        status = napi_create_int32(env, static_cast<int32_t>(arg), &enumValue);
        AKI_DCHECK(status == napi_ok);
        return enumValue;
    }

    static napi_value ToNapiValueFunction(napi_env env, const T& arg, std::false_type)
    {
        napi_status status;
        std::unique_ptr<T> headArg = std::make_unique<T>(std::move(arg));
        napi_value external;
        static const char* hint = "AKI-external";
        status = napi_create_external(env, headArg.release(), FinalizeTest, const_cast<char*>(hint), &external);
        AKI_DCHECK(status == napi_ok);

        const napi_ref* consRef = Class<T>::GetInstance().GetClassRefs();
        napi_value cons;
        if (consRef == nullptr || *consRef == nullptr) {
            AKI_LOG(ERROR) << "consRef can't be nullptr!";
            return nullptr;
        }
        status = napi_get_reference_value(env, *consRef, &cons);
        AKI_DCHECK(status == napi_ok);

        size_t argc = 2;
        napi_value typeFlag;
        napi_create_uint32(env, static_cast<uint32_t>(TypeFlag::IS_SHARED_PTR), &typeFlag);
        napi_value args[2] = {external, typeFlag};
        napi_value instance;
        status = napi_new_instance(env, cons, argc, args, &instance);
        AKI_DCHECK(status == napi_ok);
        return instance;
    }

    static napi_value ToNapiValue(napi_env env, const T& arg)
    {
        AKI_DLOG(DEBUG) << "ToNapiValue for object";

        return ToNapiValueFunction(env, arg, std::is_enum<T>());
    }
#else
    static napi_value ToNapiValue(napi_env env, const T& arg)
    {
        AKI_DLOG(DEBUG) << "ToNapiValue for object";
        napi_status status;
        napi_value nullValue = nullptr;
        if (env == nullptr) {
            AKI_LOG(ERROR) << "env can't be nullptr!";
            return nullValue;
        }

        if constexpr (std::is_enum<T>::value) {
            napi_value enumValue;
            status = napi_create_int32(env, static_cast<int32_t>(arg), &enumValue);
            AKI_DCHECK(status == napi_ok);
            return enumValue;
        }

        if (reinterpret_cast<const void*>(&arg) == nullptr) {
            status = napi_get_null(env, &nullValue);
            AKI_DCHECK(status == napi_ok);
            return nullValue;
        }

        std::unique_ptr<T> headArg = std::make_unique<T>(std::move(arg));
        napi_value external;
        static const char* hint = "AKI-external"; // napi_create_external 3rd/4th params required
        status = napi_create_external(env, headArg.release(), FinalizeTest,
            const_cast<char*>(hint), &external);
        AKI_DCHECK(status == napi_ok);

        const napi_ref* consRef = Class<T>::GetInstance().GetClassRefs();
        napi_value cons;
        if (consRef == nullptr || *consRef == nullptr) {
            AKI_LOG(ERROR) << "consRef can't be nullptr!";
            return nullValue;
        }
        status = napi_get_reference_value(env, *consRef, &cons);
        AKI_DCHECK(status == napi_ok);

        size_t argc = 2;
        napi_value typeFlag;
        napi_create_uint32(env, static_cast<uint32_t>(TypeFlag::IS_SHARED_PTR), &typeFlag);
        napi_value args[2] = {external, typeFlag};
        napi_value instance;
        status = napi_new_instance(env, cons, argc, args, &instance);
        AKI_DCHECK(status == napi_ok);
        return instance;
    }
#endif

    // 获取对象引用
    void* GetDataReference() override
    {
        return ClassWrapper<typename ValueDefiner<T>::RawType>::UnWrapper(env_, value_);
    }

    // 获取对象引用
    T GetEnumeration()
    {
        int32_t result;
        napi_status status = napi_get_value_int32(env_, value_, &result);
        AKI_DCHECK(status == napi_ok);
        return static_cast<T>(result);
    }

    static bool CheckType(napi_env env, napi_value value)
    {
#if USING_CXX_STANDARD_11
        if (std::is_enum<T>::value) {
#else
        if constexpr (std::is_enum<T>::value) {
#endif
            napi_status status;
            napi_valuetype type;
            status = napi_typeof(env, value, &type);
            AKI_DCHECK(status == napi_ok);
            return type == napi_number;
        } else {
            return NapiObjectValue::CheckType(env, value);
        }
    }

    static constexpr const char* ExpectedType()
    {
#if USING_CXX_STANDARD_11
        if (std::is_enum<T>::value) {
#else
        if constexpr (std::is_enum<T>::value) {
#endif
            return "number";
        } else {
            return NapiObjectValue::ExpectedType();
        }
    }
};

template<typename T>
class NapiValue<T*> : public NapiObjectValue {
public:
    using NapiObjectValue::NapiObjectValue;

    static napi_value ToNapiValue(napi_env env, T* arg)
    {
        AKI_DLOG(DEBUG) << "ToNapiValue for object pointer: " << arg;
        napi_status status;
        napi_value nullValue;
        status = napi_get_null(env, &nullValue);

        if (arg == nullptr) {
            return nullValue;
        }
        
        napi_value external;
        static const char* hint = "AKI-external ptr"; // napi_create_external params
        status = napi_create_external(env, arg, FinalizeTest,
            const_cast<char*>(hint), &external);
        AKI_DCHECK(status == napi_ok);

        const napi_ref* consRef = Class<T>::GetInstance().GetClassRefs();
        napi_value cons;
        if (consRef == nullptr || *consRef == nullptr) {
            AKI_LOG(ERROR) << "consRef can't be nullptr!";
            return nullValue;
        }
        status = napi_get_reference_value(env, *consRef, &cons);
        AKI_DCHECK(status == napi_ok);

        size_t argc = 2;
        napi_value typeFlag;
        napi_create_uint32(env, static_cast<uint32_t>(TypeFlag::IS_POINTER), &typeFlag);
        napi_value args[2] = {external, typeFlag};
        napi_value instance;
        status = napi_new_instance(env, cons, argc, args, &instance);
        AKI_DCHECK(status == napi_ok);
        return instance;
    }

    // 获取对象引用
    void* GetDataReference() override
    {
        return ClassWrapper<typename ValueDefiner<T>::RawType>::UnWrapper(env_, value_);
    }
};

// napi_value
template<>
class NapiValue<napi_value> : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    static napi_value ToNapiValue(napi_env env, napi_value value)
    {
        return value;
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        return true;
    }

    static constexpr const char* ExpectedType()
    {
        return "any";
    }
};

// Value
template<>
class NapiValue<aki::Value> : public NapiValue<napi_value> {
public:
    using NapiValue<napi_value>::NapiValue;

    static napi_value ToNapiValue(napi_env env, aki::Value&& value)
    {
        return value.GetHandle();
    }

    static napi_value ToNapiValue(napi_env env, aki::Value& value)
    {
        return value.GetHandle();
    }
};

template <> class NapiValue<aki::Value &> : public NapiValue<napi_value> {
public:
    using NapiValue<napi_value>::NapiValue;

    static napi_value ToNapiValue(napi_env env, aki::Value&& value)
    {
        return value.GetHandle();
    }

    static napi_value ToNapiValue(napi_env env, aki::Value& value)
    {
        return value.GetHandle();
    }
};

// std::shared_ptr
template<typename T>
class NapiValue<std::shared_ptr<T>> : public NapiObjectValue {
public:
    using NapiObjectValue::NapiObjectValue;

    static napi_value ToNapiValue(napi_env env, std::shared_ptr<T> arg)
    {
        AKI_DLOG(DEBUG) << "ToNapiValue for std::shared_ptr object pointer: " << arg.get();
        napi_status status;
        napi_value nullValue;
        status = napi_get_null(env, &nullValue);
        AKI_DCHECK(status == napi_ok);

        if (arg == nullptr) {
            return nullValue;
        }

        // 重新申请堆内存，避免 std::shared_ptr 生命周期结束释放对象
        std::unique_ptr<T> headArg = std::make_unique<T>(std::move(*arg));
        napi_value external;
        static const char* hint = "AKI-external ptr"; // napi_create_external params
        status = napi_create_external(env, headArg.release(), FinalizeTest,
            const_cast<char*>(hint), &external);
        AKI_DCHECK(status == napi_ok);

        // consRef may be null if class forgot Binding, need null check here
        const napi_ref* consRef = Class<T>::GetInstance().GetClassRefs();
        if (consRef == nullptr || *consRef == nullptr) {
            AKI_LOG(ERROR) << "consRef can't be nullptr!";
            return nullValue;
        }
        napi_value cons;
        status = napi_get_reference_value(env, *consRef, &cons);
        AKI_DCHECK(status == napi_ok);

        size_t argc = 2;
        napi_value typeFlag;
        napi_create_uint32(env, static_cast<uint32_t>(TypeFlag::IS_SHARED_PTR), &typeFlag);
        napi_value args[2] = {external, typeFlag};
        napi_value instance;
        status = napi_new_instance(env, cons, argc, args, &instance);
        AKI_DCHECK(status == napi_ok);
        return instance;
    }

    // 获取对象引用
    void* GetDataReference() override
    {
        return ClassWrapper<typename ValueDefiner<T>::RawType>::GetShared(env_, value_);
    }
};

// bool
template<>
class NapiValue<bool> : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    /// bool类型转napi_value
    static napi_value ToNapiValue(napi_env env, bool value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_get_boolean(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        return CheckBoolType(env, value);
    }

    static constexpr const char* ExpectedType()
    {
        return "boolean";
    }
};

// number base
class NapiNumberValue : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    static bool CheckType(napi_env env, napi_value value)
    {
        return CheckNumberType(env, value);
    }

    static constexpr const char* ExpectedType()
    {
        return "number";
    }
};

// uint8_t
template<>
class NapiValue<uint8_t> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// uint8_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, uint8_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        uint32_t num = static_cast<uint32_t>(value);
        status = napi_create_uint32(env, num, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// int8_t
template<>
class NapiValue<int8_t> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// int8_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, int8_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        int32_t num = static_cast<int32_t>(value);
        status = napi_create_int32(env, num, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// uint16_t
template<>
class NapiValue<uint16_t> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// uint16_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, uint16_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        uint32_t num = static_cast<uint32_t>(value);
        status = napi_create_uint32(env, num, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// int16_t
template<>
class NapiValue<int16_t> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// int16_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, int16_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        int32_t num = static_cast<int32_t>(value);
        status = napi_create_int32(env, num, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// int32_t
template<>
class NapiValue<int32_t> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// int32_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, int32_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_int32(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

template <>
class NapiValue<int32_t &> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// int32_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, int32_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_int32(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// uint32_t
template<>
class NapiValue<uint32_t>: public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    // uint32_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, uint32_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_uint32(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// uint64_t
template<>
class NapiValue<uint64_t> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    // uint64_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, uint64_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_bigint_uint64(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// int64_t
template<>
class NapiValue<int64_t> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// int64_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, int64_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_int64(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

template <>
class NapiValue<int64_t &> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// int64_t 类型转napi_value
    static napi_value ToNapiValue(napi_env env, int64_t value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_int64(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// double
template<>
class NapiValue<double> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// double类型转napi_value
    static napi_value ToNapiValue(napi_env env, double value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_double(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

template <>
class NapiValue<double &> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// double类型转napi_value
    static napi_value ToNapiValue(napi_env env, double value)
    {
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_double(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

// float
template<>
class NapiValue<float> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// float 类型转napi_value
    static napi_value ToNapiValue(napi_env env, float value)
    {
        napi_status status;
        napi_value result = nullptr;

        status = napi_create_double(env, static_cast<double>(value), &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

template <>
class NapiValue<float &> : public NapiNumberValue {
public:
    using NapiNumberValue::NapiNumberValue;

    /// float 类型转napi_value
    static napi_value ToNapiValue(napi_env env, float value)
    {
        napi_status status;
        napi_value result = nullptr;

        status = napi_create_double(env, static_cast<double>(value), &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }
};

class NapiStringValue : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    ~NapiStringValue()
    {
        if (cStr_ != nullptr) {
            delete[] cStr_;
        }
    }

    /// char* 类型转napi_value
    static napi_value ToNapiValue(napi_env env, const char* value)
    {
        FUNCTION_DTRACE();
        napi_status status;
        napi_value result = nullptr;
        status = napi_create_string_utf8(env, value, std::strlen(value), &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }

    char* GetCString() override
    {
        FUNCTION_DTRACE();
        napi_status status;
        size_t length = 0;
        status = napi_get_value_string_utf8(env_, value_, nullptr, 0, &length);
        AKI_DCHECK(status == napi_ok);
        AKI_DCHECK(cStr_ == nullptr);
        AKI_DCHECK((length+1) < std::numeric_limits<size_t>::max());
        cStr_ = new char[length+1];
        status = napi_get_value_string_utf8(env_, value_, cStr_, length+1, &length);
        AKI_DCHECK(status == napi_ok);
        return cStr_;
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        return CheckStringType(env, value);
    }

    static constexpr const char* ExpectedType()
    {
        return "string";
    }

protected:
    char* cStr_ = nullptr;
};

// char*
template<>
class NapiValue<char*> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;
};

template <>
class NapiValue<char *&> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;
};

// const char*
template<>
class NapiValue<const char*> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;
};

template <>
class NapiValue<const char *&> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;
};

// const char [N]
template<size_t N>
class NapiValue<const char [N]> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;
};

template <size_t N>
class NapiValue<const char (&)[N]> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;
};

// char [N]
template<size_t N>
class NapiValue<char [N]> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;
};

template <size_t N>
class NapiValue<char (&)[N]> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;
};

// std::string
template<>
class NapiValue<std::string> : public NapiStringValue {
public:
    using NapiStringValue::NapiStringValue;

    /// string类型转napi_value
    static napi_value ToNapiValue(napi_env env, std::string value)
    {
        return NapiStringValue::ToNapiValue(env, value.c_str());
    }
};

// std::vector
template<typename T>
class NapiValue<std::vector<T>> : public NapiValueBase {
public:
    NapiValue<std::vector<T>>(napi_env env, napi_value value)
        : NapiValueBase(env, value)
    {
        obj_ = GetVector();
    }

    static napi_value ToNapiValue(napi_env env, std::vector<T> value)
    {
        napi_status status;
        napi_value result = nullptr;

        status = napi_create_array(env, &result);
        AKI_DCHECK(status == napi_ok);
        for (uint32_t i = 0; i < value.size(); i++) {
            napi_value element = NapiValue<T>::ToNapiValue(env, std::forward<T>(value[i]));

            status = napi_set_element(env, result, i, element);
            AKI_DCHECK(status == napi_ok);
        }
        return result;
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        return CheckArrayType(env, value);
    }

    static constexpr const char* ExpectedType()
    {
        return "array";
    }

    // 获取对象引用
    void* GetDataReference() override
    {
        return &obj_;
    }

private:
    std::vector<T> GetVector();

    std::vector<T> obj_;
};

// std::array
template<typename T, size_t N>
class NapiValue<std::array<T, N>> : public NapiValueBase {
public:
    NapiValue<std::array<T, N>>(napi_env env, napi_value value)
        : NapiValueBase(env, value)
    {
        obj_ = GetArray();
    }

    static napi_value ToNapiValue(napi_env env, std::array<T, N> value)
    {
        napi_status status;
        napi_value result = nullptr;

        status = napi_create_array(env, &result);
        AKI_DCHECK(status == napi_ok);
        for (uint32_t i = 0; i < value.size(); i++) {
            napi_value element = NapiValue<T>::ToNapiValue(env, value[i]);

            status = napi_set_element(env, result, i, element);
            AKI_DCHECK(status == napi_ok);
        }
        return result;
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        napi_status status;
        bool result;
        status = napi_is_array(env, value, &result);
        AKI_DCHECK(status == napi_ok);
        return result;
    }

    static constexpr const char* ExpectedType()
    {
        return "array";
    }

    // 获取对象引用
    void* GetDataReference() override
    {
        return &obj_;
    }

private:
    std::array<T, N> GetArray();

    std::array<T, N> obj_;
};

// function base
class NapiFunctionValue : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    static bool CheckType(napi_env env, napi_value value)
    {
        return CheckFunctionType(env, value);
    }

    static constexpr const char* ExpectedType()
    {
        return "function";
    }
};

// std::function
template<typename R, typename... P>
class NapiValue<std::function <R (P...)>> : public NapiFunctionValue {
public:
    NapiValue<std::function <R (P...)>>(napi_env env, napi_value value)
        : obj_(SafetyCallback<R (P...)>(env, value)), NapiFunctionValue(env, value)
    {}
    // 触发GC时，回收资源
    static void Finalize(napi_env env, void* finalize_data, void* finalize_hint)
    {
        std::function<R (P...)> *data = reinterpret_cast<std::function<R (P...)> *> (finalize_data);
        delete data;
        data = nullptr;
    }
    /// bool类型转napi_value
    static napi_value ToNapiValue(napi_env env, std::function<R (P...)> value)
    {
        napi_status status;
        napi_value result = nullptr;
        auto invoke = std::make_unique<std::function<R (P...)>>(std::move(value));
        std::function <R (P...)> *func = invoke.release();
        status = napi_create_function(env, "", NAPI_AUTO_LENGTH, NapiCallbackBinder<R, P...>::Wrapper, func, &result);
        AKI_DCHECK(status == napi_ok);
        status = napi_add_finalizer(env, result, func, Finalize, nullptr, nullptr);
        AKI_DCHECK(status == napi_ok);
        return result;
    }

    // 获取对象引用
    void* GetDataReference() override
    {
        return &obj_;
    }

private:
    std::function <R (P...)> obj_;
};

// Callback<R>
template<typename R, typename... P>
class NapiValue<Callback<R (P...)>> : public NapiFunctionValue {
public:
    using NapiFunctionValue::NapiFunctionValue;

    Callback<R (P...)> GetFunction() const
    {
        return Callback<R (P...)>(env_, value_);
    }
};

// SafetyCallback<R(P...)>
template<typename R, typename... P>
class NapiValue<SafetyCallback<R (P...)>> : public NapiFunctionValue {
public:
    using NapiFunctionValue::NapiFunctionValue;

    SafetyCallback<R(P...)> GetFunction() const
    {
        return SafetyCallback<R(P...)>(env_, value_);
    }
};

// Equivalent type from JavaScript
template<typename T>
class NapiValue<Equivalence<T>> : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    void* GetDataReference() override
    {
        AKI_DLOG(DEBUG) << "NapiValue<Equivalence<T>>::GetDataReference";
        napi_env env = env_;

        napi_value str;
        napi_create_string_utf8(env, "equals", NAPI_AUTO_LENGTH, &str);
        napi_value equals;
        napi_get_property(env,
                          value_,
                          str,
                          &equals);
        napi_valuetype type;
        napi_typeof(env, equals, &type);
        AKI_DCHECK(type == napi_function);

        Callback<void (napi_value)> converter(env, equals);

        TemplatedArgStorage<T> storage(Class<T>::GetInstance().GetValueConstructorGroupId());

        napi_value target = value_;
        napi_value storageFunc;
        napi_create_function(env,
                             "",
                             NAPI_AUTO_LENGTH,
                             NapiOverloader::CreateValue,
                             &storage,
                             &storageFunc);

        converter.CallMethod(env, target, storageFunc);

        return storage.TaskClass();
    }
};

template<>
class NapiValue<JSFunction> : public NapiFunctionValue {
public:
    using NapiFunctionValue::NapiFunctionValue;

    JSFunction GetJSFunction()
    {
        return JSFunction(env_, value_);
    }
};

// ArrayBuffer
template<>
class NapiValue<ArrayBuffer> : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    static napi_value ToNapiValue(napi_env env, ArrayBuffer value)
    {
        return value.GetHandle();
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        napi_status status;
        bool isArrayBuffer;
        status = napi_is_arraybuffer(env, value, &isArrayBuffer);
        AKI_DCHECK(status == napi_ok);
        bool isTypedArray;
        status = napi_is_typedarray(env, value, &isTypedArray);
        AKI_DCHECK(status == napi_ok);
        return isArrayBuffer || isTypedArray;
    }

    static constexpr const char* ExpectedType()
    {
        return "ArrayBuffer | TypedArray";
    }
};

// Promise
template<>
class NapiValue<Promise> : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;

    static napi_value ToNapiValue(napi_env env, Promise&& value)
    {
        return value.GetHandle();
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        return CheckObjectType(env, value);
    }

    static constexpr const char* ExpectedType()
    {
        return "Promise";
    }
};

// std::map<K, T>
template<typename K, typename T>
class NapiValue<std::map<K, T>> : public NapiValueBase {
public:
    NapiValue<std::map<K, T>>(napi_env env, napi_value value)
        : NapiValueBase(env, value)
    {
        GetMapObject();
    }

#if USING_CXX_STANDARD_11
    static void GetMapKey(napi_env env, napi_value& napiKey, K& key, std::true_type)
    {
        napiKey = key.GetHandle();
    }
    static void GetMapKey(napi_env env, napi_value& napiKey, K& key, std::false_type)
    {
        napiKey = NapiValue<K>::ToNapiValue(env, key);
    }
#endif
    static napi_value ToNapiValue(napi_env env, std::map<K, T> mapObj)
    {
        napi_status status;
        napi_value obj;

        status = napi_create_object(env, &obj);
        AKI_DCHECK(status == napi_ok);

#if USING_CXX_STANDARD_11
        for (auto it = mapObj.begin(); it != mapObj.end(); ++it) {
            auto key = it->first;
            auto value = it->second;
#else
        for (auto [key, value] : mapObj) {
#endif
            napi_value napiKey;
#if USING_CXX_STANDARD_11
            GetMapKey(env, napiKey, key, std::is_same<K, aki::Value>());
#else
            if constexpr (std::is_same<K, aki::Value>::value) {
                napiKey = key.GetHandle();
            } else {
                napiKey = NapiValue<K>::ToNapiValue(env, key);
            }
#endif
            napi_value napiValue = NapiValue<T>::ToNapiValue(env, std::forward<T>(value));
            status = napi_set_property(env, obj, napiKey, napiValue);
            AKI_DCHECK(status == napi_ok);
        }

        return obj;
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        napi_status status;
        napi_valuetype type;
        status = napi_typeof(env, value, &type);
        AKI_DCHECK(status == napi_ok);
        return type == napi_object;
    }

    static constexpr const char* ExpectedType()
    {
        return "object";
    }

    // 获取对象引用
    void* GetDataReference() override
    {
        return &obj_;
    }

private:
    void GetMapObject();
    void GetMapInfo();

    std::map<K, T> obj_;
};

// std::unordered_map<K, T>
template<typename K, typename T, typename H>
class NapiValue<std::unordered_map<K, T, H>> : public NapiValueBase {
public:
    NapiValue<std::unordered_map<K, T, H>>(napi_env env, napi_value value)
        : NapiValueBase(env, value)
    {
        GetHashMapObject();
    }

#if USING_CXX_STANDARD_11
    static void GetHahMapKey(napi_env env, napi_value& napiKey, K& key, std::true_type)
    {
        napiKey = key.GetHandle();
    }
    static void GetHahMapKey(napi_env env, napi_value& napiKey, K& key, std::false_type)
    {
        napiKey = NapiValue<K>::ToNapiValue(env, key);
    }
#endif
    static napi_value ToNapiValue(napi_env env, std::unordered_map<K, T, H> mapObj)
    {
        napi_status status;
        napi_value obj;

        status = napi_create_object(env, &obj);
        AKI_DCHECK(status == napi_ok);

#if USING_CXX_STANDARD_11
        for (auto it = mapObj.begin(); it != mapObj.end(); ++it) {
            auto key = it->first;
            auto value = it->second;
#else
        for (auto [key, value] : mapObj) {
#endif
            napi_value napiKey;
#if USING_CXX_STANDARD_11
            GetHahMapKey(env, napiKey, key, std::is_same<K, aki::Value>());
#else
            if constexpr (std::is_same<K, aki::Value>::value) {
                napiKey = key.GetHandle();
            } else {
                napiKey = NapiValue<K>::ToNapiValue(env, key);
            }
#endif
            napi_value napiValue = NapiValue<T>::ToNapiValue(env, std::forward<T>(value));
            status = napi_set_property(env, obj, napiKey, napiValue);
            AKI_DCHECK(status == napi_ok);
        }

        return obj;
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        napi_status status;
        napi_valuetype type;
        status = napi_typeof(env, value, &type);
        AKI_DCHECK(status == napi_ok);
        return type == napi_object;
    }

    static constexpr const char* ExpectedType()
    {
        return "object";
    }

    // 获取对象引用
    void* GetDataReference() override
    {
        return &obj_;
    }

private:
    void GetHashMapObject();
    void GetHashMapInfo();

    std::unordered_map<K, T, H> obj_;
};

// std::unordered_set<T>
template<typename T, typename H>
class NapiValue<std::unordered_set<T, H>> : public NapiValueBase {
public:
    NapiValue<std::unordered_set<T, H>>(napi_env env, napi_value value)
        : NapiValueBase(env, value)
    {
        GetHashSetObject();
    }

#if USING_CXX_STANDARD_11
    static void GetSetValue(napi_env env, napi_value& napiValue, const T& value, std::true_type)
    {
        napiValue = value.GetHandle();
    }
    static void GetSetValue(napi_env env, napi_value& napiValue, const T& value, std::false_type)
    {
        napiValue = NapiValue<T>::ToNapiValue(env, value);
    }
#endif
    static napi_value ToNapiValue(napi_env env, std::unordered_set<T, H> setObj)
    {
        napi_status status;
        napi_value obj;

        status = napi_create_array_with_length(env, setObj.size(), &obj);
        AKI_DCHECK(status == napi_ok);

        size_t index = 0;
        for (const auto& value : setObj) {
            napi_value napiValue;
#if USING_CXX_STANDARD_11
            GetSetValue(env, napiValue, value, std::is_same<T, aki::Value>());
#else
            if constexpr (std::is_same<T, aki::Value>::value) {
                napiValue = value.GetHandle();
            } else {
                napiValue = NapiValue<T>::ToNapiValue(env, value);
            }
#endif

            status = napi_set_element(env, obj, index++, napiValue);
            AKI_DCHECK(status == napi_ok);
        }

        return obj;
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        napi_status status;
        napi_valuetype type;
        status = napi_typeof(env, value, &type);
        AKI_DCHECK(status == napi_ok);
        return type == napi_object;
    }

    static constexpr const char* ExpectedType()
    {
        return "object";
    }

    // 获取对象引用
    void* GetDataReference() override
    {
        return &obj_;
    }

private:
    void GetHashSetObject();
    void GetHashSetInfo();

    std::unordered_set<T, H> obj_;
};

#ifndef USING_CXX_STANDARD_11

template<typename T>
class NapiValue<std::optional<T>> : public NapiValueBase {
public:
    using NapiValueBase::NapiValueBase;
    NapiValue<std::optional<T>>(napi_env env, napi_value value) : NapiValueBase(env, value)
    {
        obj_ = GetOptional();
    }

    static napi_value ToNapiValue(napi_env env, std::optional<T> optValue)
    {
        if (!optValue.has_value()) {
            napi_value undefined;
            napi_status status = napi_get_undefined(env, &undefined);
            AKI_DCHECK(status == napi_ok);
            return undefined;
        }

        return NapiValue<T>::ToNapiValue(env, optValue.value());
    }

    static bool CheckType(napi_env env, napi_value value)
    {
        napi_status status;
        napi_valuetype type;
        status = napi_typeof(env, value, &type);
        AKI_DCHECK(status == napi_ok);
        return type == napi_undefined || NapiValue<T>::CheckType(env, value);
    }

    void* GetDataReference() override
    {
        return &obj_;
    }

    static constexpr const char* ExpectedType()
    {
        return "optional";
    }

private:
    std::optional<T> GetOptional();

    std::optional<T> obj_;
};

#endif

} // namespace aki
#endif //AKI_NAPI_VALUE_H
