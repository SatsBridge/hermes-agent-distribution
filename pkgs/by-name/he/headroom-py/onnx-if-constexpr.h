#ifndef ABSL_UTILITY_INTERNAL_IF_CONSTEXPR_H_
#define ABSL_UTILITY_INTERNAL_IF_CONSTEXPR_H_

#include <utility>

namespace absl {
namespace utility_internal {

template <bool Condition, typename TrueFunc, typename FalseFunc, typename... Args>
auto IfConstexprElse(TrueFunc&& true_func, FalseFunc&& false_func, Args&&... args) {
  if constexpr (Condition) {
    return std::forward<TrueFunc>(true_func)(std::forward<Args>(args)...);
  } else {
    return std::forward<FalseFunc>(false_func)(std::forward<Args>(args)...);
  }
}

}  // namespace utility_internal
}  // namespace absl

#endif
