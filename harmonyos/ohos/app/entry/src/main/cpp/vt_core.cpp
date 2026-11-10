// vt_core.cpp —— 最小 VT 解析器（M1 的终端网格核心）
//
// 范围（只承诺能被 fixture 逐项断言的部分）：
//   CUP(H/f) · CUU/CUD/CUF/CUB(A/B/C/D) · CHA(G) · VPA(d)
//   ED(J) 0/1/2 · EL(K) 0/1/2 · SGR(m) 前景色与 0/39 重置
//   CR/LF/换行滚动 · 退格 · UTF-8 解码（含跨 chunk 的半截序列）· CJK 宽字符双宽单元格
//
// 刻意不做（写进 RUNBOOK，不假装）：备用屏、回滚缓冲、组合字符与零宽连接符、
// 连字、SIXEL/Kitty/iTerm2 图片、鼠标上报、DECSET 2026、选择/复制、pty 尺寸协商。
//
// 为什么 CJK 要单独处理：终端是固定网格，一个汉字的显示宽度是 2 列。
// 若按 1 列存放，`abc|中文|def` 这类行会与真实终端错位，中文用户第一眼就能看出不对。
#include <napi/native_api.h>

#include <map>
#include <string>
#include <vector>

namespace {

struct Cell {
    std::string glyph;  // UTF-8；空表示"宽字符的右半格"或空格
    int fg = 0;
    bool blank = true;   // 真空白（用于 screenText 去尾随空格）
};

constexpr int kMaxCols = 400;
constexpr int kMaxRows = 200;

// 粗略的宽度判定：覆盖常见东亚宽字符区段。精确实现应查 wcwidth 表，
// 这里按"足够覆盖 CJK/全角/韩文"的区段近似，并在 RUNBOOK 里写明这是近似。
bool isWideRune(unsigned int cp) {
    if (cp >= 0x1100 && cp <= 0x115F) return true;    // Hangul Jamo
    if (cp >= 0x2E80 && cp <= 0x303E) return true;    // CJK 部首/标点
    if (cp >= 0x3041 && cp <= 0x33FF) return true;    // 假名/CJK 兼容
    if (cp >= 0x3400 && cp <= 0x4DBF) return true;    // CJK 扩展 A
    if (cp >= 0x4E00 && cp <= 0x9FFF) return true;    // CJK 基本区
    if (cp >= 0xA000 && cp <= 0xA4CF) return true;    // 彝文
    if (cp >= 0xAC00 && cp <= 0xD7A3) return true;    // 韩文音节
    if (cp >= 0xF900 && cp <= 0xFAFF) return true;    // CJK 兼容表意
    if (cp >= 0xFE30 && cp <= 0xFE6F) return true;    // CJK 兼容形式
    if (cp >= 0xFF00 && cp <= 0xFF60) return true;    // 全角 ASCII
    if (cp >= 0xFFE0 && cp <= 0xFFE6) return true;    // 全角符号
    if (cp >= 0x20000 && cp <= 0x3FFFD) return true;  // 扩展 B+
    return false;
}

std::string encodeUtf8(unsigned int cp) {
    std::string out;
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
    return out;
}

struct Screen {
    int cols = 80;
    int rows = 24;
    int curRow = 0;
    int curCol = 0;
    int fg = 0;
    std::vector<Cell> cells;
    std::string utf8Pending;  // 跨 chunk 的半截 UTF-8 序列

    // 回滚缓冲：行被滚动顶出时进入这里。只保留文本，不保留颜色/宽字符标记——
    // 够用且省内存；若将来要"回滚区也能着色"，需要把 Cell 行一起存。
    std::vector<std::string> history;
    static constexpr size_t kMaxHistory = 2000;

    // 备用屏：进替代屏时保存主屏与光标，退出时恢复（DECSET 47/1047/1049）
    bool altActive = false;
    std::vector<Cell> savedCells;
    int savedRow = 0;
    int savedCol = 0;

    void resize(int c, int r) {
        cols = c < 8 ? 8 : (c > kMaxCols ? kMaxCols : c);
        rows = r < 4 ? 4 : (r > kMaxRows ? kMaxRows : r);
        cells.assign(static_cast<size_t>(cols) * static_cast<size_t>(rows), Cell{});
        curRow = 0;
        curCol = 0;
        fg = 0;
        utf8Pending.clear();
        history.clear();
        altActive = false;
        savedCells.clear();
    }

    Cell &at(int row, int col) {
        return cells[static_cast<size_t>(row) * static_cast<size_t>(cols) + static_cast<size_t>(col)];
    }

    void clearRow(int row) {
        for (int c = 0; c < cols; c++) {
            at(row, c) = Cell{};
        }
    }

    std::string rowText(int row) const {
        std::string line;
        for (int c = 0; c < cols; c++) {
            const Cell &cell = cells[static_cast<size_t>(row) * static_cast<size_t>(cols) + static_cast<size_t>(c)];
            line += cell.blank ? std::string(" ") : cell.glyph;
        }
        while (!line.empty() && line.back() == ' ') {
            line.pop_back();
        }
        return line;
    }

    void pushHistory(int row) {
        // 备用屏里的滚动不进主屏历史（真实终端也不进）
        if (altActive) {
            return;
        }
        history.push_back(rowText(row));
        if (history.size() > kMaxHistory) {
            history.erase(history.begin());
        }
    }

    void scroll() {
        pushHistory(0);
        for (int r = 1; r < rows; r++) {
            for (int c = 0; c < cols; c++) {
                at(r - 1, c) = at(r, c);
            }
        }
        clearRow(rows - 1);
    }

    void newline() {
        curRow++;
        if (curRow >= rows) {
            curRow = rows - 1;
            scroll();
        }
    }

    void enterAlt(bool saveCursor) {
        if (altActive) {
            return;
        }
        savedCells = cells;
        savedRow = curRow;
        savedCol = curCol;
        altActive = true;
        // 1049 会先清屏；47/1047 保留内容。这里统一清屏，行为更可预测。
        cells.assign(static_cast<size_t>(cols) * static_cast<size_t>(rows), Cell{});
        (void)saveCursor;
    }

    void leaveAlt() {
        if (!altActive) {
            return;
        }
        cells = savedCells;
        curRow = savedRow < rows ? savedRow : rows - 1;
        curCol = savedCol < cols ? savedCol : cols - 1;
        altActive = false;
        savedCells.clear();
    }

    void putGlyph(const std::string &glyph, int width) {
        if (width <= 0) {
            width = 1;
        }
        if (curCol + width > cols) {
            curCol = 0;
            newline();
        }
        Cell &cell = at(curRow, curCol);
        cell.glyph = glyph;
        cell.fg = fg;
        cell.blank = false;
        curCol++;
        if (width == 2) {
            // 右半格标记为"被占据但无字形"，让 screenText 与光标推进都正确
            Cell &right = at(curRow, curCol);
            right.glyph.clear();
            right.fg = fg;
            right.blank = false;
            curCol++;
        }
    }
};

// 实例注册表：每个会话标签一个网格（含自己的历史缓冲与备用屏）。
// NAPI 调用都发生在一个 JS 线程上（含 TSFN 回调），所以这里不加锁；
// 若将来从 C 线程直接调用，需要补 mutex。
std::map<int, Screen *> g_screens;
int g_nextScreenId = 1;

Screen &screenOf(int id) {
    auto it = g_screens.find(id);
    if (it == g_screens.end()) {
        // 未知 id：返回一个进程内的兜底屏幕，避免解引用空指针
        static Screen fallback;
        return fallback;
    }
    return *it->second;
}

std::vector<int> parseParams(const std::string &body) {
    std::vector<int> out;
    int value = -1;
    for (char ch : body) {
        if (ch >= '0' && ch <= '9') {
            value = (value < 0 ? 0 : value) * 10 + (ch - '0');
        } else if (ch == ';') {
            out.push_back(value < 0 ? 0 : value);
            value = -1;
        }
    }
    out.push_back(value < 0 ? 0 : value);
    return out;
}

int argOr(const std::vector<int> &p, size_t i, int fallback) {
    if (i >= p.size() || p[i] == 0) {
        return fallback;
    }
    return p[i];
}

void clampCursor(Screen &s) {
    if (s.curRow < 0) s.curRow = 0;
    if (s.curRow >= s.rows) s.curRow = s.rows - 1;
    if (s.curCol < 0) s.curCol = 0;
    if (s.curCol >= s.cols) s.curCol = s.cols - 1;
}

void dispatchCsi(Screen &s, const std::string &body, char final) {
    // 私有模式：形如 "?1049h" / "?47l"。parseParams 会忽略 '?'，这里据首字符判定。
    if (!body.empty() && body[0] == '?' && (final == 'h' || final == 'l')) {
        const std::vector<int> mp = parseParams(body.substr(1));
        const bool enable = (final == 'h');
        for (int mode : mp) {
            if (mode == 47 || mode == 1047 || mode == 1049) {
                if (enable) {
                    s.enterAlt(mode == 1049);
                } else {
                    s.leaveAlt();
                }
            }
        }
        return;
    }

    const std::vector<int> p = parseParams(body);
    switch (final) {
        case 'H':
        case 'f':
            s.curRow = argOr(p, 0, 1) - 1;
            s.curCol = argOr(p, 1, 1) - 1;
            break;
        case 'A': s.curRow -= argOr(p, 0, 1); break;
        case 'B': s.curRow += argOr(p, 0, 1); break;
        case 'C': s.curCol += argOr(p, 0, 1); break;
        case 'D': s.curCol -= argOr(p, 0, 1); break;
        case 'G': s.curCol = argOr(p, 0, 1) - 1; break;
        case 'd': s.curRow = argOr(p, 0, 1) - 1; break;
        case 'J': {
            const int mode = p.empty() ? 0 : p[0];
            if (mode == 2) {
                for (int r = 0; r < s.rows; r++) s.clearRow(r);
            } else if (mode == 1) {
                for (int c = 0; c <= s.curCol && c < s.cols; c++) s.at(s.curRow, c) = Cell{};
                for (int r = 0; r < s.curRow; r++) s.clearRow(r);
            } else {
                for (int c = s.curCol; c < s.cols; c++) s.at(s.curRow, c) = Cell{};
                for (int r = s.curRow + 1; r < s.rows; r++) s.clearRow(r);
            }
            break;
        }
        case 'K': {
            const int mode = p.empty() ? 0 : p[0];
            if (mode == 2) {
                s.clearRow(s.curRow);
            } else if (mode == 1) {
                for (int c = 0; c <= s.curCol && c < s.cols; c++) s.at(s.curRow, c) = Cell{};
            } else {
                for (int c = s.curCol; c < s.cols; c++) s.at(s.curRow, c) = Cell{};
            }
            break;
        }
        case 'm': {
            for (size_t i = 0; i < p.size(); i++) {
                const int v = p[i];
                if (v == 0 || v == 39) {
                    s.fg = 0;
                } else if (v >= 30 && v <= 37) {
                    s.fg = v;
                }
            }
            break;
        }
        default: break;
    }
    clampCursor(s);
}

// UTF-8 解码：把累积的 pending 里能完整解出的码点逐个交给 putGlyph，
// 半截序列留在 pending 里等下一个 chunk（流式场景下这个边界必然发生）。
void drainUtf8(Screen &s) {
    std::string &buf = s.utf8Pending;
    size_t i = 0;
    while (i < buf.size()) {
        const unsigned char b0 = static_cast<unsigned char>(buf[i]);
        size_t need = 0;
        unsigned int cp = 0;
        if (b0 < 0x80) {
            need = 1;
            cp = b0;
        } else if ((b0 & 0xE0) == 0xC0) {
            need = 2;
            cp = b0 & 0x1F;
        } else if ((b0 & 0xF0) == 0xE0) {
            need = 3;
            cp = b0 & 0x0F;
        } else if ((b0 & 0xF8) == 0xF0) {
            need = 4;
            cp = b0 & 0x07;
        } else {
            buf.erase(0, i + 1);  // 非法首字节：丢弃
            i = 0;
            continue;
        }
        if (i + need > buf.size()) {
            break;  // 半截，等下一个 chunk
        }
        bool ok = true;
        for (size_t k = 1; k < need; k++) {
            const unsigned char bk = static_cast<unsigned char>(buf[i + k]);
            if ((bk & 0xC0) != 0x80) {
                ok = false;
                break;
            }
            cp = (cp << 6) | (bk & 0x3F);
        }
        if (!ok) {
            buf.erase(0, i + 1);
            i = 0;
            continue;
        }
        if (cp < 0x20) {
            // 控制字符已在别处处理；这里丢弃
        } else {
            s.putGlyph(encodeUtf8(cp), isWideRune(cp) ? 2 : 1);
        }
        i += need;
    }
    if (i > 0) {
        buf.erase(0, i);
    }
}

void feed(Screen &s, const char *data, size_t len) {
    enum class State { Ground, Esc, Csi, Osc, OscEsc } state = State::Ground;
    std::string csiBody;
    for (size_t i = 0; i < len; i++) {
        const unsigned char raw = static_cast<unsigned char>(data[i]);
        switch (state) {
            case State::Ground:
                if (raw == 0x1B) {
                    drainUtf8(s);  // 先把挂起的多字节收干净
                    state = State::Esc;
                } else if (raw == '\r') {
                    drainUtf8(s);
                    s.curCol = 0;
                } else if (raw == '\n') {
                    drainUtf8(s);
                    s.newline();
                } else if (raw == '\b') {
                    drainUtf8(s);
                    if (s.curCol > 0) s.curCol--;
                } else if (raw < 0x20) {
                    // 其它控制字符忽略
                } else {
                    s.utf8Pending.push_back(static_cast<char>(raw));
                    drainUtf8(s);
                }
                break;
            case State::Esc:
                if (raw == '[') {
                    state = State::Csi;
                    csiBody.clear();
                } else if (raw == ']') {
                    state = State::Osc;   // OSC：到 BEL 或 ST(ESC \) 结束，内容整段丢弃
                } else {
                    state = State::Ground;
                }
                break;
            case State::Osc:
                if (raw == 0x07) {
                    state = State::Ground;
                } else if (raw == 0x1B) {
                    state = State::OscEsc;
                }
                break;
            case State::OscEsc:
                // ST = ESC \；其它情况按 OSC 内容继续吞掉
                state = (raw == '\\') ? State::Ground : State::Osc;
                break;
            case State::Csi:
                if (raw >= 0x40 && raw <= 0x7E) {
                    dispatchCsi(s, csiBody, static_cast<char>(raw));
                    state = State::Ground;
                } else {
                    csiBody.push_back(static_cast<char>(raw));
                }
                break;
        }
    }
    drainUtf8(s);
}

std::string screenText(Screen &s) {
    std::string out;
    for (int r = 0; r < s.rows; r++) {
        std::string line;
        for (int c = 0; c < s.cols; c++) {
            const Cell &cell = s.at(r, c);
            if (cell.blank) {
                line.push_back(' ');
            } else {
                line += cell.glyph;  // 宽字符右半格 glyph 为空，不产生字符
            }
        }
        while (!line.empty() && line.back() == ' ') {
            line.pop_back();
        }
        if (line.empty() && r == s.rows - 1) {
            break;
        }
        out += line;
        out.push_back('\n');
    }
    while (!out.empty() && out.back() == '\n') {
        out.pop_back();
    }
    return out;
}

std::string screenStatus(Screen &s) {
    int colored = 0;
    int wide = 0;
    for (const Cell &cell : s.cells) {
        if (!cell.blank && cell.fg != 0) colored++;
    }
    for (int r = 0; r < s.rows; r++) {
        for (int c = 0; c < s.cols; c++) {
            const Cell &cell = s.at(r, c);
            if (!cell.blank && cell.glyph.size() >= 3) wide++;
        }
    }
    char buf[160];
    snprintf(buf, sizeof(buf), "cur=%d,%d colors=%d wide=%d hist=%d alt=%d size=%dx%d",
             s.curRow + 1, s.curCol + 1, colored, wide,
             static_cast<int>(s.history.size()), s.altActive ? 1 : 0,
             s.cols, s.rows);
    return std::string(buf);
}

std::string historyTail(Screen &s, int n) {
    if (n <= 0 || s.history.empty()) {
        return std::string();
    }
    const size_t total = s.history.size();
    const size_t take = static_cast<size_t>(n) < total ? static_cast<size_t>(n) : total;
    std::string out;
    for (size_t i = total - take; i < total; i++) {
        out += s.history[i];
        out.push_back('\n');
    }
    while (!out.empty() && out.back() == '\n') {
        out.pop_back();
    }
    return out;
}

std::string getString(napi_env env, napi_value v) {
    size_t len = 0;
    napi_get_value_string_utf8(env, v, static_cast<char *>(nullptr), 0, &len);
    if (len == 0) {
        return std::string();
    }
    std::string s;
    s.resize(len);
    napi_get_value_string_utf8(env, v, &s[0], len + 1, &len);
    return s;
}

// ---------------- NAPI ----------------
// 旧接口（不带 id）作用于"默认实例"0，保持已有 spec 与代码不变；
// 新接口带 id，供多标签会话各用一块网格。

Screen &defaultScreen() {
    static bool inited = false;
    if (!inited) {
        auto *s = new Screen();
        s->resize(80, 24);
        g_screens[0] = s;
        inited = true;
    }
    return screenOf(0);
}

napi_value vtNew(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t cols = 80;
    int32_t rows = 24;
    if (argc > 0) napi_get_value_int32(env, args[0], &cols);
    if (argc > 1) napi_get_value_int32(env, args[1], &rows);
    auto *screen = new Screen();
    screen->resize(cols, rows);
    const int id = g_nextScreenId++;
    g_screens[id] = screen;
    napi_value out = nullptr;
    napi_create_int32(env, id, &out);
    return out;
}

napi_value vtFree(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t id = 0;
    napi_get_value_int32(env, args[0], &id);
    auto it = g_screens.find(id);
    int freed = 0;
    if (it != g_screens.end() && id != 0) {   // 默认实例不允许释放
        delete it->second;
        g_screens.erase(it);
        freed = 1;
    }
    napi_value out = nullptr;
    napi_create_int32(env, freed, &out);
    return out;
}

napi_value vtReset(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    // vtReset(cols, rows) 或 vtReset(id, cols, rows)
    int id = 0;
    int base = 0;
    if (argc >= 3) {
        napi_get_value_int32(env, args[0], &id);
        base = 1;
    }
    int32_t cols = 80;
    int32_t rows = 24;
    if (argc > base) napi_get_value_int32(env, args[base], &cols);
    if (argc > base + 1) napi_get_value_int32(env, args[base + 1], &rows);
    if (argc >= 3) {
        Screen &s = screenOf(id);
        s.resize(cols, rows);
    } else {
        defaultScreen().resize(cols, rows);
    }
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value vtFeed(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    // vtFeed(data) 或 vtFeed(id, data)
    if (argc >= 2) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        const std::string data = getString(env, args[1]);
        feed(screenOf(id), data.data(), data.size());
    } else {
        const std::string data = getString(env, args[0]);
        feed(defaultScreen(), data.data(), data.size());
    }
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value vtScreen(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string text;
    if (argc >= 1) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        text = screenText(screenOf(id));
    } else {
        text = screenText(defaultScreen());
    }
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

napi_value vtStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string text;
    if (argc >= 1) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        text = screenStatus(screenOf(id));
    } else {
        text = screenStatus(defaultScreen());
    }
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

napi_value vtScrollBack(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    // vtScrollBack(n) 或 vtScrollBack(id, n)
    if (argc >= 2) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        int32_t n = 5;
        napi_get_value_int32(env, args[1], &n);
        const std::string text = historyTail(screenOf(id), n);
        napi_value out = nullptr;
        napi_create_string_utf8(env, text.c_str(), text.size(), &out);
        return out;
    }
    int32_t n = 5;
    if (argc >= 1) napi_get_value_int32(env, args[0], &n);
    const std::string text = historyTail(defaultScreen(), n);
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

}  // namespace

void RegisterVtFunctions(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"vtNew", nullptr, vtNew, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtFree", nullptr, vtFree, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtReset", nullptr, vtReset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtFeed", nullptr, vtFeed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtScreen", nullptr, vtScreen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtStatus", nullptr, vtStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtScrollBack", nullptr, vtScrollBack, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    (void)defaultScreen();
}
