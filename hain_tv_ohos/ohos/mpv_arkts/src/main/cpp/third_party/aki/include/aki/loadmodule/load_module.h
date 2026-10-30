/*
 * Copyright (C) 2024 Huawei Device Co., Ltd.
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

#ifndef __LOAD_MODULE_H__
#define __LOAD_MODULE_H__

#include <string>
#include "aki/value.h"

#ifdef __OHOS__
namespace aki {

class AKI_EXPORT LoadModule {
public:
    LoadModule()
    {}
    ~LoadModule()
    {}
    /**
     * func: 加载模块。
     * 注意：使用此接口的前提是需要将模块在工程中参照openharmony官网进行配置。
     *
     * params:
     *  modulePath: 加载的文件路径或者模块名
     *  moduleInfo: bundleName/moduleName的路径拼接,
     *              当此字段为空时只局限于在主线程中进行模块加载
     *
     * return: 加载的模块
     * **/
    static aki::Value Load(std::string modulePath, std::string moduleInfo="");
};   // class LoadModule
} // namespace aki
#endif

#endif  /* __LOAD_MODULE_H__ */
