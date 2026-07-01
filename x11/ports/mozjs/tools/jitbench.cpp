// jitbench.cpp — interpreter-vs-JIT benchmark for SpiderMonkey 115 on iOS (#46).
// One binary, one engine: runs each workload with the JIT fully OFF (pure C++ interpreter)
// then fully ON (Baseline interp + Baseline JIT + Ion), toggled at runtime via
// JS_SetGlobalJitCompilerOption. So the delta measured is purely the JIT, not a build diff.
//
// Build on-device:
//   clang++ -std=c++17 -O2 jitbench.cpp $(pkg-config --cflags --libs mozjs-115) -o jitbench
//   ldid -S<ent-jit.xml> jitbench    # dynamic-codesigning
//   ./jitbench
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <mach/mach_time.h>

#include "jsapi.h"
#include "js/Initialization.h"
#include "js/CompilationAndEvaluation.h"
#include "js/SourceText.h"
#include "js/RealmOptions.h"
#include "js/Conversions.h"

static const JSClass GlobalClass = {"global", JSCLASS_GLOBAL_FLAGS,
                                    &JS::DefaultGlobalClassOps};

static double g_ns_per_tick = 0;
static uint64_t now_ticks() { return mach_absolute_time(); }
static double ticks_to_ms(uint64_t d) {
  if (g_ns_per_tick == 0) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    g_ns_per_tick = (double)tb.numer / (double)tb.denom;
  }
  return (double)d * g_ns_per_tick / 1.0e6;
}

// Fully enable/disable the JIT tiers at runtime.
static void set_jit(JSContext* cx, bool on) {
  uint32_t v = on ? 1 : 0;
  JS_SetGlobalJitCompilerOption(cx, JSJITCOMPILER_BASELINE_INTERPRETER_ENABLE, v);
  JS_SetGlobalJitCompilerOption(cx, JSJITCOMPILER_BASELINE_ENABLE, v);
  JS_SetGlobalJitCompilerOption(cx, JSJITCOMPILER_ION_ENABLE, v);
  // Default warmup thresholds are fine: the workloads call their hot functions far more times
  // than the Ion trigger (~1000), so Baseline+Ion engage well within each run.
}

static bool eval_num(JSContext* cx, const char* code, double* out) {
  JS::CompileOptions opts(cx);
  opts.setFileAndLine("bench.js", 1);
  JS::SourceText<mozilla::Utf8Unit> src;
  if (!src.init(cx, code, strlen(code), JS::SourceOwnership::Borrowed)) return false;
  JS::RootedValue rval(cx);
  if (!JS::Evaluate(cx, opts, src, &rval)) {
    if (JS_IsExceptionPending(cx)) {
      JS::RootedValue exc(cx);
      JS_GetPendingException(cx, &exc);
      JS_ClearPendingException(cx);
      fprintf(stderr, "  JS exception during eval\n");
    }
    return false;
  }
  double d = 0;
  if (!JS::ToNumber(cx, rval, &d)) return false;
  *out = d;
  return true;
}

struct Workload {
  const char* name;
  const char* code;
};

// Each workload returns a numeric checksum (so both modes are verified identical).
static const Workload WORKLOADS[] = {
    {"arith-loop",
     "var r=0;"
     "function f(n){var s=0;for(var i=0;i<n;i++){s=(s+i*3+7)|0;s=(s^(i<<1))|0;s=(s+(i*i))|0;}return s|0;}"
     "for(var k=0;k<3000;k++){r=(r+f(3000))|0;}"
     "r|0;"},
    {"fib-recursive",
     "function fib(n){return n<2?n:fib(n-1)+fib(n-2);}"
     "var r=0;for(var k=0;k<60;k++){r+=fib(30);}r;"},
    {"obj-prop-string",
     "function g(n){var t=0;for(var i=0;i<n;i++){var o={a:i,b:i+1,c:i*2};var s=''+o.a+'-'+o.c;t+=o.a+o.b+o.c+s.length;}return t;}"
     "var r=0;for(var k=0;k<1500;k++){r+=g(2000);}r;"},
};

static double bench_min_ms(JSContext* cx, const char* code, int reps, double* checksum) {
  double best = 1e18;
  for (int i = 0; i < reps; i++) {
    double v = 0;
    uint64_t t0 = now_ticks();
    if (!eval_num(cx, code, &v)) return -1;
    uint64_t t1 = now_ticks();
    double ms = ticks_to_ms(t1 - t0);
    if (ms < best) best = ms;
    *checksum = v;
  }
  return best;
}

int main(int argc, char** argv) {
  if (!JS_Init()) { fprintf(stderr, "JS_Init failed\n"); return 1; }
  JSContext* cx = JS_NewContext(256L * 1024 * 1024);
  if (!cx) { fprintf(stderr, "JS_NewContext failed\n"); return 1; }
  if (!JS::InitSelfHostedCode(cx)) { fprintf(stderr, "InitSelfHostedCode failed\n"); return 1; }

  JS::RealmOptions ro;
  JS::RootedObject global(cx, JS_NewGlobalObject(cx, &GlobalClass, nullptr,
                                                 JS::FireOnNewGlobalHook, ro));
  if (!global) { fprintf(stderr, "JS_NewGlobalObject failed\n"); return 1; }
  JSAutoRealm ar(cx, global);

  const int REPS = 8;
  printf("%-18s %12s %12s %9s  %s\n", "workload", "interp(ms)", "jit(ms)", "speedup", "checksum-match");
  printf("%-18s %12s %12s %9s  %s\n", "--------", "----------", "-------", "-------", "--------------");

  for (const auto& w : WORKLOADS) {
    // interpreter first: JIT off from the start so no jitcode is ever created
    set_jit(cx, false);
    double sum_i = 0;
    double interp = bench_min_ms(cx, w.code, REPS, &sum_i);

    // then JIT on
    set_jit(cx, true);
    double sum_j = 0;
    double jit = bench_min_ms(cx, w.code, REPS, &sum_j);

    if (interp < 0 || jit < 0) {
      printf("%-18s  FAILED\n", w.name);
      continue;
    }
    printf("%-18s %12.2f %12.2f %8.2fx  %s (%.0f)\n", w.name, interp, jit,
           interp / jit, (sum_i == sum_j ? "yes" : "NO"), sum_j);
  }

  // Confirm the JIT tiers report as enabled (sanity that we really toggled).
  uint32_t ion = 0, base = 0, bi = 0;
  JS_GetGlobalJitCompilerOption(cx, JSJITCOMPILER_ION_ENABLE, &ion);
  JS_GetGlobalJitCompilerOption(cx, JSJITCOMPILER_BASELINE_ENABLE, &base);
  JS_GetGlobalJitCompilerOption(cx, JSJITCOMPILER_BASELINE_INTERPRETER_ENABLE, &bi);
  printf("\nfinal JIT state: ion=%u baseline=%u baseline-interp=%u\n", ion, base, bi);
  return 0;
}
