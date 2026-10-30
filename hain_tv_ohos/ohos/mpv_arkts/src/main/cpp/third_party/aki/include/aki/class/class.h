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

#ifndef AKI_CLASS_H
#define AKI_CLASS_H

#include "class_base.h"
#include "aki/overloader/napi/napi_overloader.h"
#include "aki/logging/logging.h"

namespace aki {
template <typename C>
class Class : public ClassBase {
public:
    Class() = default;

    ~Class() = default;

    static Class<C>& GetInstance()
    {
        static Class<C> instance;
        return instance;
    }

    void AddConstructor(Binder* binder)
    {
        binder_ = binder;
        NapiOverloader::AddMethod(wrapperConstructorGroupId_,
                                  binder->GetArity(),
                                  binder->GetWrapper());

        NapiOverloader::AddMethod(valueConstructorGroupId_,
                                  binder->GetArity(),
                                  binder->GetValueConstructor());
    }

    const napi_ref* GetClassRefs() override
    {
        AKI_LOG(DEBUG) << "class:" << GetName() << " GetClassRefs : " << tlsRef;
        return tlsRef;
    }

    void SetClassRefs(napi_ref* originalRef) override
    {
        tlsRef = originalRef;
    }

private:
    static thread_local napi_ref* tlsRef;
};
template <typename C>
thread_local napi_ref* Class<C>::tlsRef = nullptr;
} // namespace aki

#endif //AKI_CLASS_H
