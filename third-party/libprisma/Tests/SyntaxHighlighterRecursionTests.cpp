// Regression test for the unbounded-recursion DoS in the code-block syntax
// highlighter (see the "brightscript" report). A short message whose language
// is a Prism grammar with a token cycle (directive-statement -> expression ->
// directive-statement) drove SyntaxHighlighter::tokenize()/matchGrammar() into
// unbounded mutual recursion and exhausted the thread stack (SIGSEGV into the
// guard page) as soon as the block was highlighted.
//
// The fix bounds the grammar recursion with a depth counter. This test loads
// the real shipped grammars.dat (passed as argv[1] via the BUILD `args`) and
// highlights the report's payload; before the fix it crashes, after the fix it
// returns and highlighting stays lossless (the concatenated text is unchanged).
//
// Pure C++ host test, following the CHECK_TRUE + main() pattern of the tgcalls
// cc_tests. No gtest dependency.

#include "SyntaxHighlighter.h"
#include "TokenList.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

static int g_failures = 0;

#define CHECK_TRUE(cond, msg)                                              \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__,    \
                         __LINE__);                                        \
            ++g_failures;                                                  \
        } else {                                                          \
            std::fprintf(stderr, "ok: %s\n", (msg));                       \
        }                                                                  \
    } while (0)

// Flatten a highlighted TokenList back to its plain text, mirroring the paint
// walk in Syntaxer.mm: Text nodes contribute their value, Syntax nodes recurse
// into their children. Highlighting must be lossless.
static void appendNode(const TokenListNode& node, std::string& out) {
    if (node.isSyntax()) {
        const auto& syntax = dynamic_cast<const Syntax&>(node);
        for (auto it = syntax.begin(); it != syntax.end(); ++it) {
            appendNode(*it, out);
        }
    } else {
        const auto& text = dynamic_cast<const Text&>(node);
        out.append(text.value());
    }
}

static std::string flatten(const TokenList& tokens) {
    std::string out;
    for (auto it = tokens.begin(); it != tokens.end(); ++it) {
        appendNode(*it, out);
    }
    return out;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <path-to-grammars.dat>\n", argv[0]);
        return 2;
    }

    std::ifstream f(argv[1], std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "cannot open grammars.dat at %s\n", argv[1]);
        return 2;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    std::string grammars = ss.str();
    CHECK_TRUE(grammars.size() > 100000, "grammars.dat loaded");

    SyntaxHighlighter highlighter(grammars);

    // The DoS payload: a "brightscript" code block. Before the depth bound this
    // recurses without limit and the process dies with a stack overflow, so
    // simply reaching the assertions below is the core of the regression.
    {
        const std::string code = "#iFclude <a>";
        TokenList tokens = highlighter.tokenize(code, "brightscript");
        CHECK_TRUE(flatten(tokens) == code,
                   "brightscript DoS payload highlights losslessly without overflow");
    }

    // Longer minimised variants from the report, all previously crashing.
    for (const std::string& code : {std::string("#iFclude <a>2}"),
                                    std::string("#iFclude <a>2}ss"),
                                    std::string("#iFncLude x <a>\fracde <a>\frac{{1}{2}")}) {
        TokenList tokens = highlighter.tokenize(code, "brightscript");
        CHECK_TRUE(flatten(tokens) == code,
                   "brightscript variant highlights losslessly without overflow");
    }

    // Controls: benign inputs must still be highlighted and stay lossless.
    {
        const std::string code = "print 1";
        TokenList tokens = highlighter.tokenize(code, "brightscript");
        CHECK_TRUE(flatten(tokens) == code, "benign brightscript stays lossless");
    }
    {
        const std::string code = "var x = 1; function f() { return x; }";
        TokenList tokens = highlighter.tokenize(code, "javascript");
        CHECK_TRUE(flatten(tokens) == code, "javascript stays lossless");
    }

    // Bounded work: the cycle in brightscript is cut by the depth cap, and the cut is reported.
    {
        const std::string code = "#iFclude <a>";
        TokenizeStats stats;
        TokenList tokens = highlighter.tokenize(code, "brightscript", &stats);
        CHECK_TRUE(flatten(tokens) == code, "cyclic grammar stays lossless with stats");
        CHECK_TRUE(stats.depthLimited, "cyclic grammar reports the depth cap");
        CHECK_TRUE(stats.maxDepth <= SyntaxHighlighter::kMaxTokenizeDepth + 1, "recursion depth never passes the cap");
    }

    // Deeply nested input: thousands of open template-literal substitutions.
    {
        std::string code;
        for (int i = 0; i < 6000; ++i) {
            code += "`${";
        }
        TokenizeStats stats;
        TokenList tokens = highlighter.tokenize(code, "javascript", &stats);
        CHECK_TRUE(flatten(tokens) == code, "deeply nested javascript stays lossless");
        CHECK_TRUE(stats.maxDepth <= SyntaxHighlighter::kMaxTokenizeDepth + 1, "nesting depth never passes the cap");
    }

    // Regex-heavy input: the number of regex searches is bounded by the size of the text, and the
    // tokens found before the budget ran out are kept.
    {
        const std::vector<std::string> languages = {"javascript", "python", "markup", "cpp", "bash", "css", "json", "ruby", "php", "sql"};
        const std::vector<std::string> units = {"x = \"", "/*", "<!--", "`${", "a", "{[(", "#iFclude <a>", "'\\", "(?:", "\\u{"};
        bool everBounded = true;
        size_t exhausted = 0;
        size_t worstMs = 0;
        for (const auto& language : languages) {
            for (const auto& unit : units) {
                std::string code;
                while (code.size() < 6000) {
                    code += unit;
                }
                TokenizeStats stats;
                auto from = std::chrono::steady_clock::now();
                TokenList tokens = highlighter.tokenize(code, language, &stats);
                auto ms = (size_t)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - from).count();
                worstMs = std::max(worstMs, ms);
                exhausted += stats.budgetExhausted ? 1 : 0;
                if (flatten(tokens) != code || stats.searches > SyntaxHighlighter::kSearchesPerByte * code.size() + SyntaxHighlighter::kSearchesAtLeast) {
                    everBounded = false;
                    std::fprintf(stderr, "unbounded: %s / %s searches=%zu\n", language.c_str(), unit.c_str(), stats.searches);
                }
            }
        }
        CHECK_TRUE(everBounded, "regex searches stay within the per-byte budget and output stays lossless");
        std::fprintf(stderr, "worst adversarial highlight: %zu ms, budget exhausted in %zu cases\n", worstMs, exhausted);
        CHECK_TRUE(worstMs < 20000, "adversarial blocks finish in bounded time");
    }

    // A tiny budget runs out, says so, and keeps every character.
    {
        const std::string code = "function f(a) { return a + `x${a}` /* c */; }\nvar s = 'str'; var t = \"two\"; // end\n";
        const TokenizeLimits limits{0, 5};
        TokenizeStats stats;
        TokenList tokens = highlighter.tokenize(code, "javascript", &stats, &limits);
        CHECK_TRUE(stats.budgetExhausted, "a tiny budget is reported as exhausted");
        CHECK_TRUE(stats.searches <= 5, "no search runs past the budget");
        CHECK_TRUE(flatten(tokens) == code, "an exhausted budget keeps the text lossless");
    }

    // A long input stays within the budget and returns every character.
    {
        std::string code(30000, 'a');
        TokenizeStats stats;
        TokenList tokens = highlighter.tokenize(code, "javascript", &stats);
        CHECK_TRUE(flatten(tokens) == code, "long input stays lossless");
        CHECK_TRUE(stats.searches <= SyntaxHighlighter::kSearchesPerByte * code.size() + SyntaxHighlighter::kSearchesAtLeast, "long input stays within budget");
    }

    // One highlighter is shared by several threads.
    {
        const std::string code = "function f(a) { return a + `x${a}` /* c */; }\nvar s = 'str';";
        const std::string expected = flatten(highlighter.tokenize(code, "javascript"));
        std::vector<std::thread> threads;
        std::vector<int> ok(8, 0);
        for (int t = 0; t < 8; ++t) {
            threads.emplace_back([&, t]() {
                bool good = true;
                for (int i = 0; i < 20; ++i) {
                    good = good && flatten(highlighter.tokenize(code, "javascript")) == expected;
                }
                ok[t] = good ? 1 : 0;
            });
        }
        for (auto& thread : threads) {
            thread.join();
        }
        int total = 0;
        for (int v : ok) {
            total += v;
        }
        CHECK_TRUE(total == 8, "concurrent tokenize on one highlighter is consistent");
    }

    // Language parity with the macOS app: the TON languages and the Kotlin, VB, Handlebars and Wolfram aliases.
    {
        const auto languages = highlighter.languages();
        for (const char* name : {"fc", "fift", "func", "tact", "tl", "tlb", "tolk", "kt", "vb", "hbs", "wl"}) {
            CHECK_TRUE(languages.count(name) == 1, name);
        }
    }

    if (g_failures == 0) {
        std::fprintf(stderr, "ALL PASS\n");
        return 0;
    }
    std::fprintf(stderr, "%d FAILURE(S)\n", g_failures);
    return 1;
}
