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
#include "aki/value/napi/napi_value_base.h"
#include "aki/logging/logging.h"
#include "status/status.h"
namespace aki {

// | static |
bool NapiValueBase::CheckUndefinedType(napi_env env, napi_value value)
{
    napi_valuetype type = napi_undefined;
    napi_status status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);
    return type == napi_undefined;
}

// | static |
bool NapiValueBase::CheckNullType(napi_env env, napi_value value)
{
    napi_valuetype type = napi_null;
    napi_status status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);
    return type == napi_null;
}

// | static |
bool NapiValueBase::CheckBoolType(napi_env env, napi_value value)
{
    napi_valuetype type = napi_boolean;
    napi_status status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);
    return type == napi_boolean;
}

// | static |
bool NapiValueBase::CheckNumberType(napi_env env, napi_value value)
{
    napi_valuetype type = napi_number;
    napi_status status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);
    return type == napi_number;
}

// | static |
bool NapiValueBase::CheckStringType(napi_env env, napi_value value)
{
    napi_valuetype type = napi_string;
    napi_status status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);
    return type == napi_string;
}

// | static |
bool NapiValueBase::CheckObjectType(napi_env env, napi_value value)
{
    napi_valuetype type = napi_object;
    napi_status status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);
    return type == napi_object;
}

// | static |
bool NapiValueBase::CheckArrayType(napi_env env, napi_value value)
{
    bool result = false;
    napi_status status = napi_is_array(env, value, &result);
    AKI_DCHECK(status == napi_ok);
    return result;
}

// | static |
bool NapiValueBase::CheckFunctionType(napi_env env, napi_value value)
{
    napi_valuetype type = napi_function;
    napi_status status = napi_typeof(env, value, &type);
    AKI_DCHECK(status == napi_ok);
    return type == napi_function;
}

// | static |
// napi_create_external 3rd/4th params required, differs from Node.js spec
void NapiValueBase::FinalizeTest(napi_env env, void* nativeInstance, void* finalizeHint)
{
    const char* hint = reinterpret_cast<const char*>(finalizeHint);
    AKI_DLOG(DEBUG) << "FinalizeTest: " << (hint == nullptr ? "unknown" : hint);
}

bool NapiValueBase::GetBool() const
{
    bool result = false;
    napi_status status = napi_get_value_bool(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return result;
}

uint8_t NapiValueBase::GetUint8() const
{
    uint32_t result = 0;
    napi_status status = napi_get_value_uint32(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return static_cast<uint8_t>(result);
}

int8_t NapiValueBase::GetInt8() const
{
    int32_t result = 0;
    napi_status status = napi_get_value_int32(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return static_cast<int8_t>(result);
}

uint16_t NapiValueBase::GetUint16() const
{
    uint32_t result = 0;
    napi_status status = napi_get_value_uint32(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return static_cast<uint16_t>(result);
}

int16_t NapiValueBase::GetInt16() const
{
    int32_t result = 0;
    napi_status status = napi_get_value_int32(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return static_cast<int16_t>(result);
}

int32_t NapiValueBase::GetInt() const
{
    int32_t result = 0;
    napi_status status = napi_get_value_int32(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return result;
}

uint32_t NapiValueBase::GetUInt() const
{
    uint32_t result = 0;
    napi_status status = napi_get_value_uint32(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return result;
}

uint64_t NapiValueBase::GetUInt64() const
{
    int64_t result = 0;
    bool lossless = false;
    napi_status status = napi_get_value_bigint_int64(env_, value_, &result, &lossless);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status) << ", lossless" << lossless;
    return result;
}
int64_t NapiValueBase::GetInt64() const
{
    napi_status status;
    int64_t result;
    status = napi_get_value_int64(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return result;
}

float NapiValueBase::GetFloat() const
{
    double result = 0.0;
    napi_status status = napi_get_value_double(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return static_cast<float>(result);
}

double NapiValueBase::GetDouble() const
{
    double result = 0.0;
    napi_status status = napi_get_value_double(env_, value_, &result);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    return result;
}

std::string NapiValueBase::GetString() const
{
    FUNCTION_DTRACE();
    size_t length = 0;
    napi_status status = napi_get_value_string_utf8(env_, value_, nullptr, 0, &length);
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);
    AKI_DCHECK((length+1) < std::numeric_limits<size_t>::max());
    std::string buf(length, '\0');
#if USING_CXX_STANDARD_11
    status = napi_get_value_string_utf8(env_, value_, (char*)buf.data(), length+1, &length);
#else
    status = napi_get_value_string_utf8(env_, value_, buf.data(), length+1, &length);
#endif
    AKI_DCHECK(status == napi_ok) << "status(" << status << "): " << GetStatusDesc(status);

    return buf;
}

napi_value NapiValueBase::GetNapiValue() const
{
    return value_;
}

ArrayBuffer NapiValueBase::GetArrayBuffer() const
{
    napi_status status;
    napi_env env = env_;
    void* data;
    size_t length;
    ArrayBuffer::Typed typed = ArrayBuffer::BUFF;

    bool isArrayBuffer;
    status = napi_is_arraybuffer(env, value_, &isArrayBuffer);
    AKI_DCHECK(status == napi_ok) << "status: " << status;

    if (isArrayBuffer) {
        status = napi_get_arraybuffer_info(env, value_, &data, &length);
        AKI_DCHECK(status == napi_ok) << "status: " << status;
    } else {
        napi_typedarray_type type;
        napi_value buffer;
        size_t offset;
        status = napi_get_typedarray_info(env, value_, &type, &length, &data, &buffer, &offset);
        AKI_DCHECK(status == napi_ok) << "status: " << status;
        typed = static_cast<ArrayBuffer::Typed>(type);
    }

    return ArrayBuffer(value_, reinterpret_cast<uint8_t *>(data), length, typed);
}

// 获取对象引用
void* NapiValueBase::GetDataReference()
{
    AKI_DCHECK(false);
    return nullptr;
}

Promise NapiValueBase::GetPromise()
{
    return Promise(value_);
}

bool NapiValueBase::IsUndefined() const
{
    return CheckUndefinedType(env_, value_);
}

bool NapiValueBase::IsNull() const
{
    return CheckNullType(env_, value_);
}

bool NapiValueBase::IsBool() const
{
    return CheckBoolType(env_, value_);
}

bool NapiValueBase::IsNumber() const
{
    return CheckNumberType(env_, value_);
}

bool NapiValueBase::IsString() const
{
    return CheckStringType(env_, value_);
}

bool NapiValueBase::IsObject() const
{
    return CheckObjectType(env_, value_);
}

bool NapiValueBase::IsArray() const
{
    return CheckArrayType(env_, value_);
}

bool NapiValueBase::IsFunction() const
{
    return CheckFunctionType(env_, value_);
}

} // namespace aki