// Message widgets run untrusted JavaScript as soon as a chat shows them (tg-widget-rce, 2026-11-11). Each case below is a
// published trigger for a memory-safety bug fixed in TelegramMessenger/quickjs master (b526a81); see VENDOR.md, change 14.
// Run it under AddressSanitizer as well (bazel test --features=asan): the use-after-free cases only show there.
#include "quickjs.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(c, name) do { if (!(c)) { failures++; printf("FAIL %s\n", name); } else { printf("ok   %s\n", name); } } while (0)

typedef enum { EXPECT_VALUE, EXPECT_SYNTAX_ERROR, EXPECT_NO_CRASH } Expectation;

static int run(const char *name, const char *code, Expectation expectation, const char *expected_value)
{
    JSRuntime *rt = JS_NewRuntime();
    JS_SetMaxStackSize(rt, 6 * 1024 * 1024);
    JSContext *ctx = JS_NewContext(rt);
    JSValue v = JS_Eval(ctx, code, strlen(code), name, JS_EVAL_TYPE_GLOBAL);
    int ok = 0;
    if (JS_IsException(v)) {
        JSValue e = JS_GetException(ctx);
        const char *s = JS_ToCString(ctx, e);
        printf("     %s threw: %s\n", name, s ? s : "?");
        ok = expectation == EXPECT_NO_CRASH || (expectation == EXPECT_SYNTAX_ERROR && s && strstr(s, "SyntaxError") == s);
        JS_FreeCString(ctx, s);
        JS_FreeValue(ctx, e);
    } else if (expectation == EXPECT_VALUE) {
        const char *s = JS_ToCString(ctx, v);
        ok = s && strcmp(s, expected_value) == 0;
        if (!ok) {
            printf("     %s returned: %s\n", name, s ? s : "?");
        }
        JS_FreeCString(ctx, s);
    } else {
        ok = expectation == EXPECT_NO_CRASH;
    }
    JS_FreeValue(ctx, v);
    JS_RunGC(rt);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return ok;
}

int main(void)
{
    // 3e236cb: a direct eval whose environment overflows the 16-bit closure_var_count.
    CHECK(run("direct-eval-closure-var-overflow",
              "var n = 32768;"
              "var inner = Function('a,'.repeat(n - 1) + 'a',"
              "  'return function(' + 'a,'.repeat(1000) + 'z,' + 'a,'.repeat(n - 1002) + 'a' + '){return eval(\\'z\\')}')();"
              "inner();",
              EXPECT_SYNTAX_ERROR, NULL), "direct-eval-closure-var-overflow");

    // 8f0d3b6: 65535 mapped parameters plus one captured local overflow the 16-bit var_ref_count.
    CHECK(run("mapped-arguments-var-ref-overflow",
              "Function('a,'.repeat(65534) + 'a', 'var x;(()=>x);return arguments');",
              EXPECT_SYNTAX_ERROR, NULL), "mapped-arguments-var-ref-overflow");

    // ca3594d: `await using` in a for head of a normal function emitted OP_await into it (use after return).
    CHECK(run("await-using-outside-async",
              "class C { static { for (await using x of []) {} } }",
              EXPECT_SYNTAX_ERROR, NULL), "await-using-outside-async");

    // 2b62af1 (#1827): RegExp bytecode freed by a lastIndex coercion and then executed.
    CHECK(run("regexp-lastindex-recompile",
              "const regexp = new RegExp('a', 'g'); let unrelated;"
              "Object.defineProperty(regexp, 'constructor', { get() {"
              "  regexp.lastIndex = { valueOf() { regexp.compile('b', 'g'); unrelated = new RegExp('c', 'g'); return 0; } };"
              "  return RegExp; } });"
              "'ccc'.replace(regexp, '') + ',' + regexp.source + ',' + unrelated.source",
              EXPECT_VALUE, "ccc,b,c"), "regexp-lastindex-recompile");

    // 3ad65ad: Map/Set.clear() walked a record freed by an iterator's finalizer.
    CHECK(run("map-clear-iterator-value",
              "const m = new Map(); m.set('a', 0); m.set('b', 1); let it = m.keys(); it.next(); it.next();"
              "m.set('a', it); it = null; m.delete('b'); m.clear();"
              "const s = new Set(); let si = s.values(); s.add(si); s.add('b'); si.next(); si.next(); si = null;"
              "s.delete('b'); s.clear(); String(m.size + s.size)",
              EXPECT_VALUE, "0"), "map-clear-iterator-value");

    // 7ca4ac5: FinalizationRegistry.unregister() freed an entry under its own walk.
    CHECK(run("finalizationregistry-unregister",
              "const registry = new FinalizationRegistry(() => {}); const token = {}; const first = {}; let second = {};"
              "registry.register(first, second, token); registry.register(second, 42, token); second = undefined;"
              "String(registry.unregister(token)) + ',' + String(registry.unregister(token))",
              EXPECT_VALUE, "true,false"), "finalizationregistry-unregister");

    // 45c5b9b: a WeakRef held as a WeakMap value for its own target aborted in reset_weak_ref().
    CHECK(run("weakref-weakmap-value",
              "(function () { let key = Symbol('key'); let ref = new WeakRef(key); const map = new WeakMap();"
              "  map.set(key, ref); ref = undefined; key = undefined; })();"
              "(function () { let key = Symbol('key'); let ref = new WeakRef(key);"
              "  const registry = new FinalizationRegistry(() => {}); registry.register(key, ref); ref = undefined; key = undefined; })();"
              "'done'",
              EXPECT_VALUE, "done"), "weakref-weakmap-value");

    printf("%s (%d failure(s))\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
