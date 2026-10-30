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

#include "aki/jsbind.h"
#include "aki/logging/logging.h"
#include "aki/value.h"
#include "status/status.h"
#include "aki/scopehandle/ScopeHandle.h"

namespace aki {

// | static |
Value Value::FromGlobal(const char* key)
{
    napi_status status;
    napi_value global;
    napi_env env = aki::JSBind::GetScopedEnv();
    
    ScopeHandle scope(env, true);
    
    status = napi_get_global(env, &global);
    AKI_DCHECK(status == napi_ok);

    napi_value result = nullptr;
    status = napi_get_named_property(env, global, key, &result);
    AKI_DCHECK(status == napi_ok);
    napi_value escapedResult = nullptr;
    scope.EscapeHandle(result, &escapedResult);

    return Value(escapedResult);
}

// | static |
Value Value::NewObject()
{
    napi_env env = aki::JSBind::GetScopedEnv();

    napi_value obj = nullptr;
    napi_status status = napi_create_object(env, &obj);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return Value(obj);
}

// | static |
Value Value::NewArray()
{
    napi_env env = aki::JSBind::GetScopedEnv();

    napi_value obj = nullptr;
    napi_status status = napi_create_array(env, &obj);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return Value(obj);
}

Value::Value()
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return;
    }
    napi_value undefined = nullptr;
    napi_status status = napi_get_undefined(env, &undefined);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);

    internal::Value* val = new NapiValueMaker<aki::Value>(aki::JSBind::GetScopedEnv(), undefined);
    handle_.reset(val);
    persistent_ = Persistent(undefined);
}

Value::Value(napi_value handle): persistent_(handle)
{
    internal::Value* val = new NapiValueMaker<aki::Value>(aki::JSBind::GetScopedEnv(), handle);
    handle_.reset(val);
}

static std::string GetString(const napi_env& env, const napi_value& value)
{
    size_t length = 0;
    auto status = napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    AKI_DCHECK(status == napi_ok);
    std::string valueStr(length, '\0');
#if USING_CXX_STANDARD_11
    status = napi_get_value_string_utf8(env, value, (char*)valueStr.data(), length+1, &length);
#else
    status = napi_get_value_string_utf8(env, value, valueStr.data(), length+1, &length);
#endif
    AKI_DCHECK(status == napi_ok);
    return valueStr;
}

static double GetNumber(const napi_env& env, const napi_value& value)
{
    double num = 0;
    auto status = napi_get_value_double(env, value, &num);
    AKI_DCHECK(status == napi_ok);
    return num;
}

bool Value::operator<(const Value& other) const
{
    if (IsString() && other.IsString()) {
        std::string thisStr = GetString(aki::JSBind::GetScopedEnv(), persistent_.GetValue());
        std::string otherStr = GetString(aki::JSBind::GetScopedEnv(), other.persistent_.GetValue());
        return thisStr < otherStr;
    } else if (IsNumber() && other.IsNumber()) {
        double thisNum = GetNumber(aki::JSBind::GetScopedEnv(), persistent_.GetValue());
        double otherNum = GetNumber(aki::JSBind::GetScopedEnv(), other.persistent_.GetValue());
        return thisNum < otherNum;
    } else if (IsString() && other.IsNumber()) {
        std::string thisStr = GetString(aki::JSBind::GetScopedEnv(), persistent_.GetValue());
        std::string otherStr = std::to_string(GetNumber(aki::JSBind::GetScopedEnv(), other.persistent_.GetValue()));
        return thisStr < otherStr;
    } else if (IsNumber() && other.IsString()) {
        std::string thisStr = std::to_string(GetNumber(aki::JSBind::GetScopedEnv(), persistent_.GetValue()));
        std::string otherStr = GetString(aki::JSBind::GetScopedEnv(), other.persistent_.GetValue());
        return thisStr < otherStr;
    }

    AKI_LOG(WARNING) << "Other data types cannot be compared.";
    return true;
}

bool Value::operator==(const Value& other) const
{
    if (IsString() && other.IsString()) {
        std::string thisStr = GetString(aki::JSBind::GetScopedEnv(), persistent_.GetValue());
        std::string otherStr = GetString(aki::JSBind::GetScopedEnv(), other.persistent_.GetValue());
        return thisStr == otherStr;
    } else if (IsNumber() && other.IsNumber()) {
        double thisNum = GetNumber(aki::JSBind::GetScopedEnv(), persistent_.GetValue());
        double otherNum = GetNumber(aki::JSBind::GetScopedEnv(), other.persistent_.GetValue());
        return thisNum == otherNum;
    } else if (IsString() && other.IsNumber()) {
        std::string thisStr = GetString(aki::JSBind::GetScopedEnv(), persistent_.GetValue());
        std::string otherStr = std::to_string(GetNumber(aki::JSBind::GetScopedEnv(), other.persistent_.GetValue()));
        return thisStr == otherStr;
    } else if (IsNumber() && other.IsString()) {
        std::string thisStr = std::to_string(GetNumber(aki::JSBind::GetScopedEnv(), persistent_.GetValue()));
        std::string otherStr = GetString(aki::JSBind::GetScopedEnv(), other.persistent_.GetValue());
        return thisStr == otherStr;
    }

    AKI_LOG(WARNING) << "Hash values cannot be computed for other data types.";
    return true;
}

Value Value::operator[](const std::string& key) const
{
    napi_status status;
    napi_value result = nullptr;
    napi_env env = aki::JSBind::GetScopedEnv();
    if (env == nullptr) {
        AKI_LOG(ERROR) << "env is null!";
        return Value(napi_undefined);
    }
    napi_value recv = persistent_.GetValue();
    if (recv == nullptr) {
        AKI_LOG(ERROR) << "recv value is null!";
        return Value(napi_undefined);
    }

    status = napi_get_named_property(env, recv, key.c_str(), &result);
    AKI_DCHECK(status == napi_ok);
    return Value(result);
}

Value Value::operator[](const size_t index) const
{
    napi_status status;
    napi_value result = nullptr;
    napi_env env = aki::JSBind::GetScopedEnv();
    napi_value array = GetHandle();
    uint32_t length;

    status = napi_get_array_length(env, array, &length);
    AKI_DCHECK(status == napi_ok);
    if (index < length) {
        status = napi_get_element(env, array, index, &result);
        AKI_DCHECK(status == napi_ok);
    } else {
        AKI_DCHECK(0) << "out range of array.";
    }
    return Value(result);
}

napi_value Value::GetHandle() const
{
    return persistent_.GetValue();
}

bool Value::IsUndefined() const
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return false;
    }
    
    napi_value value = persistent_.GetValue();
    if (nullptr == value) {
        return false;
    }
    napi_status status;
    napi_valuetype type;
    status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);

    return type == napi_undefined;
}

bool Value::IsNull() const
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return false;
    }

    napi_value value = persistent_.GetValue();
    if (nullptr == value) {
        return false;
    }
    napi_status status;
    napi_valuetype type;
    status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);

    return type == napi_null;
}

bool Value::IsBool() const
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return false;
    }

    napi_value value = persistent_.GetValue();
    if (nullptr == value) {
        return false;
    }
    napi_status status;
    napi_valuetype type;
    status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);

    return type == napi_boolean;
}

bool Value::IsNumber() const
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return false;
    }

    napi_value value = persistent_.GetValue();
    if (nullptr == value) {
        return false;
    }
    napi_status status;
    napi_valuetype type;
    status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);

    return type == napi_number;
}

bool Value::IsString() const
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return false;
    }

    napi_value value = persistent_.GetValue();
    if (nullptr == value) {
        return false;
    }
    napi_status status;
    napi_valuetype type;
    status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);

    return type == napi_string;
}

bool Value::IsObject() const
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return false;
    }

    napi_value value = persistent_.GetValue();
    if (nullptr == value) {
        return false;
    }
    napi_status status;
    napi_status statusArr;
    napi_valuetype type;
    bool isArr;
    status = napi_typeof(env, value, &type);
    statusArr = napi_is_array(env, value, &isArr);
    AKI_DCHECK(status == napi_ok);
    AKI_DCHECK(statusArr == napi_ok);

    return type == napi_object && !isArr;
}

bool Value::IsArray() const
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return false;
    }

    napi_value value = persistent_.GetValue();
    if (nullptr == value) {
        return false;
    }
    napi_status status;
    bool result;
    status = napi_is_array(env, value, &result);
    AKI_DCHECK(status == napi_ok);

    return result;
}

bool Value::IsFunction() const
{
    napi_env env = aki::JSBind::GetScopedEnv();
    if (nullptr == env) {
        return false;
    }

    napi_value value = persistent_.GetValue();
    if (nullptr == value) {
        return false;
    }
    napi_status status;
    napi_valuetype type;
    status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);

    return type == napi_function;
}

} // namespace aki
