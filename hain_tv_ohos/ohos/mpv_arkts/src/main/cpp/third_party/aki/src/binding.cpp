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

#include "aki/binding.h"

namespace aki {

namespace {
#if JSBIND_SUPPORT_DECLARATION
template<typename... T>
std::forward_list<const TypeMeta*> DefineBuildInType()
{
    static std::forward_list<const TypeMeta*> buildInTypes = { TypeTrait<T>::GetTypeMeta()... };
    return buildInTypes;
}
#endif
}

static thread_local napi_env tlsEnv;

std::unordered_map<const char*, std::forward_list<Function>> Binding::funcListMap;

std::multimap<const char*, const char*> Binding::associationClassExtendListMap;

// | static |
void Binding::SetScopedEnv(napi_env env)
{
    tlsEnv = env;
}

// | static |
napi_env Binding::GetScopedEnv()
{
    return tlsEnv;
}

// | static |
std::forward_list<Function>& Binding::GetFunctionList()
{
    static std::forward_list<Function> functionList;
    return functionList;
}

// | static |
std::forward_list<Function>& Binding::GetFunctionList(const char* module)
{
    return Binding::funcListMap[module];
}

// | static |
void Binding::RegisterFunction(const char* name, int32_t invokerId, Binder* binder)
{
    GetFunctionList().emplace_front(name, invokerId, binder);
}

// | static |
void Binding::RegisterFunction(const char* module, const char *name, int32_t invokerId, Binder* binder)
{
    GetFunctionList(module).emplace_front(name, invokerId, binder);
}

// | static |
std::forward_list<ClassBase*>& Binding::GetClassList()
{
    static std::forward_list<ClassBase*> classList;
    return classList;
}

// | static |
void Binding::RegisterClass(ClassBase* xlass)
{
    GetClassList().push_front(xlass);
}

// | static |
std::forward_list<EnumerationBase*>& Binding::GetEnumerationList()
{
    static std::forward_list<EnumerationBase*> enumerationList;
    return enumerationList;
}

// | static |
void Binding::RegisterEnumeration(EnumerationBase* enumeration)
{
    GetEnumerationList().push_front(enumeration);
}

// | static |
std::map<std::string, std::unique_ptr<JSFunction>>& Binding::GetJSFunctionMap()
{
    static std::map<std::string, std::unique_ptr<JSFunction>> jsFunctionList;
    return jsFunctionList;
}

// | static |
int Binding::RegisterJSFunction(const std::string& name, std::unique_ptr<JSFunction> func)
{
    GetJSFunctionMap()[name] = std::move(func);
    return GetJSFunctionMap().size();
}

// | static |
int Binding::UnRegisterJSFunction(const std::string& name)
{
    GetJSFunctionMap().erase(name);
    return GetJSFunctionMap().size();
}


void Binding::AssociationClassExtend(const char *name, const char *parentName)
{
    Binding::associationClassExtendListMap.emplace(name, std::move(parentName));
}

std::forward_list<const char *> Binding::GetAssociationClassExtend(const char *name)
{
    // 汇总所有继承类
    std::forward_list<const char *> extendClassList;
    // 查找继承类并设置状态进行筛选
    std::unordered_map<const char *, const bool> findClassStatusList;
    // 进行筛选的类
    std::forward_list<const char *> classList;
    // 用于每次筛选出来的新的继承类重新赋值给要进行筛选的类
    std::forward_list<const char *> tempClassList;
    auto count = Binding::associationClassExtendListMap.count(name);
    auto iter = Binding::associationClassExtendListMap.find(name);

    for (; count > 0; count--, iter++) {
        findClassStatusList.emplace(iter->second, false);
        classList.emplace_front(iter->second);
        extendClassList.emplace_front(iter->second);
    }
    if (classList.empty()) {
        return classList;
    }

    bool findEnd = false;
    while (!findEnd) {
        bool continueFind = false;
        tempClassList.clear();

        for (auto parentClass : classList) {
            auto parentClassIter = findClassStatusList.find(parentClass);
            if (parentClassIter != findClassStatusList.end() && parentClassIter->second == false) {
                findClassStatusList.emplace(parentClassIter->first, true);
                auto count = Binding::associationClassExtendListMap.count(parentClassIter->first);
                auto iter = Binding::associationClassExtendListMap.find(parentClassIter->first);
                for (; count > 0; count--, iter++) {
                    continueFind = true;
                    findClassStatusList.emplace(iter->second, false);
                    tempClassList.emplace_front(iter->second);
                    extendClassList.emplace_front(iter->second);
                }
            }
        }
        if (!continueFind) {
            findEnd = true;
            break;
        } else {
            findEnd = false;
            classList.clear();
            for (auto _class : tempClassList) {
                classList.emplace_front(_class);
            }
        }
    }
    return extendClassList;
}

#if JSBIND_SUPPORT_DECLARATION
// | static |
std::forward_list<const TypeMeta*>& Binding::GetBuildInTypeList()
{
    static std::forward_list<const TypeMeta*> typeList = DefineBuildInType<
        void, bool, nullptr_t,
        unsigned char, signed char, char,
        unsigned short, signed short,
        unsigned int, signed int,
        unsigned long,  signed long,
        unsigned long long, signed long long,
        float, double,
        char*, const char*,
        const std::string&, std::string&, std::string
    >();
    return typeList;
}
#endif

} // namespace aki