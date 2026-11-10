// vt_core.cpp —— 最小 VT 解析器（M1 的终端网格核心）
//
// 明确的取舍：这不是完整终端模拟器。只实现能被 fixture 逐项断言的部分：
//   CUP(H/f) 光标定位 · CUU/CUD/CUF/CUB(A/B/C/D) · CHA(G) · VPA(d)
//   ED(J) 0/1/2 擦除显示 · EL(K) 0/1/2 擦除行 · SGR(m) 前景色与重置
//   可打印字符 + CR/LF + 行尾换行/滚动
//
// 刻意不做（写进文档，不假装）：备用屏、回滚缓冲、宽字符/组合字符、连字、
// 图片协议（SIXEL/Kitty/iTerm2）、鼠标上报、DECSET 2026、选择/复制。
//
// 对外只暴露四个函数，便于 ArkTS 侧把"字节流"换成"网格"：
//   vtReset(cols, rows) · vtFeed(str) · vtScreen() · vtStatus()
#include <napi/native_api.h>

#include <string>
#include <vector>

namespace {

struct Cell {
    char ch = ' ';
    int fg = 0;  // 0 = 默认色；30..37 记录为前景色序号
};

constexpr int kMaxCols = 400;
constexpr int kMaxRows = 200;

struct Screen {
    int cols = 80;
    int rows = 24;
    int curRow = 0;
    int curCol = 0;
    int fg = 0;
    std::vector<Cell> cells;

    void resize(int c, int r) {
        cols = c < 8 ? 8 : (c > kMaxCols ? kMaxCols : c);
        rows = r < 4 ? 4 : (r > kMaxRows ? kMaxRows : r);
        cells.assign(static_cast<size_t>(cols) * static_cast<size_t>(rows), Cell{});
        curRow = 0;
        curCol = 0;
        fg = 0;
    }

    Cell &at(int row, int col) {
        return cells[static_cast<size_t>(row) * static_cast<size_t>(cols) + static_cast<size_t>(col)];
    }

    void clearRow(int row) {
        for (int c = 0; c < cols; c++) {
            at(row, c) = Cell{};
        }
    }

    void scroll() {
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

    void put(char ch) {
        if (curCol >= cols) {
            curCol = 0;
            newline();
        }
        Cell &cell = at(curRow, curCol);
        cell.ch = ch;
        cell.fg = fg;
        curCol++;
    }
};

Screen g_screen;

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

void dispatchCsi(const std::string &body, char final) {
    const std::vector<int> p = parseParams(body);
    switch (final) {
        case 'H':
        case 'f':
            g_screen.curRow = argOr(p, 0, 1) - 1;
            g_screen.curCol = argOr(p, 1, 1) - 1;
            break;
        case 'A':
            g_screen.curRow -= argOr(p, 0, 1);
            break;
        case 'B':
            g_screen.curRow += argOr(p, 0, 1);
            break;
        case 'C':
            g_screen.curCol += argOr(p, 0, 1);
            break;
        case 'D':
            g_screen.curCol -= argOr(p, 0, 1);
            break;
        case 'G':
            g_screen.curCol = argOr(p, 0, 1) - 1;
            break;
        case 'd':
            g_screen.curRow = argOr(p, 0, 1) - 1;
            break;
        case 'J': {
            const int mode = p.empty() ? 0 : p[0];
            if (mode == 2) {
                for (int r = 0; r < g_screen.rows; r++) {
                    g_screen.clearRow(r);
                }
            } else if (mode == 1) {
                for (int c = 0; c <= g_screen.curCol && c < g_screen.cols; c++) {
                    g_screen.at(g_screen.curRow, c) = Cell{};
                }
                for (int r = 0; r < g_screen.curRow; r++) {
                    g_screen.clearRow(r);
                }
            } else {
                for (int c = g_screen.curCol; c < g_screen.cols; c++) {
                    g_screen.at(g_screen.curRow, c) = Cell{};
                }
                for (int r = g_screen.curRow + 1; r < g_screen.rows; r++) {
                    g_screen.clearRow(r);
                }
            }
            break;
        }
        case 'K': {
            const int mode = p.empty() ? 0 : p[0];
            if (mode == 2) {
                g_screen.clearRow(g_screen.curRow);
            } else if (mode == 1) {
                for (int c = 0; c <= g_screen.curCol && c < g_screen.cols; c++) {
                    g_screen.at(g_screen.curRow, c) = Cell{};
                }
            } else {
                for (int c = g_screen.curCol; c < g_screen.cols; c++) {
                    g_screen.at(g_screen.curRow, c) = Cell{};
                }
            }
            break;
        }
        case 'm': {
            for (size_t i = 0; i < p.size(); i++) {
                const int v = p[i];
                if (v == 0 || v == 39) {
                    g_screen.fg = 0;
                } else if (v >= 30 && v <= 37) {
                    g_screen.fg = v;
                }
                // 其它 SGR（加粗/下划线/背景）暂不支持，忽略但不清空状态
            }
            break;
        }
        default:
            break;  // 未支持的 CSI 一律忽略（不破坏网格）
    }
    // 夹住光标
    if (g_screen.curRow < 0) g_screen.curRow = 0;
    if (g_screen.curRow >= g_screen.rows) g_screen.curRow = g_screen.rows - 1;
    if (g_screen.curCol < 0) g_screen.curCol = 0;
    if (g_screen.curCol >= g_screen.cols) g_screen.curCol = g_screen.cols - 1;
}

void feed(const char *data, size_t len) {
    enum class State { Ground, Esc, Csi } state = State::Ground;
    std::string csiBody;
    for (size_t i = 0; i < len; i++) {
        const unsigned char raw = static_cast<unsigned char>(data[i]);
        switch (state) {
            case State::Ground:
                if (raw == 0x1B) {
                    state = State::Esc;
                } else if (raw == '\r') {
                    g_screen.curCol = 0;
                } else if (raw == '\n') {
                    g_screen.newline();
                } else if (raw == '\b') {
                    if (g_screen.curCol > 0) g_screen.curCol--;
                } else if (raw >= 0x20 && raw < 0x7F) {
                    g_screen.put(static_cast<char>(raw));
                }
                break;
            case State::Esc:
                if (raw == '[') {
                    state = State::Csi;
                    csiBody.clear();
                } else {
                    state = State::Ground;  // 其它 ESC 序列忽略
                }
                break;
            case State::Csi:
                if (raw >= 0x40 && raw <= 0x7E) {
                    dispatchCsi(csiBody, static_cast<char>(raw));
                    state = State::Ground;
                } else {
                    csiBody.push_back(static_cast<char>(raw));
                }
                break;
        }
    }
}

std::string screenText() {
    std::string out;
    for (int r = 0; r < g_screen.rows; r++) {
        std::string line;
        for (int c = 0; c < g_screen.cols; c++) {
            line.push_back(g_screen.at(r, c).ch);
        }
        while (!line.empty() && line.back() == ' ') {
            line.pop_back();
        }
        if (line.empty() && r == g_screen.rows - 1) {
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

std::string screenStatus() {
    int colored = 0;
    for (const Cell &cell : g_screen.cells) {
        if (cell.ch != ' ' && cell.fg != 0) {
            colored++;
        }
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "cur=%d,%d colors=%d size=%dx%d",
             g_screen.curRow + 1, g_screen.curCol + 1, colored, g_screen.cols, g_screen.rows);
    return std::string(buf);
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

napi_value vtReset(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t cols = 80;
    int32_t rows = 24;
    if (argc > 0) napi_get_value_int32(env, args[0], &cols);
    if (argc > 1) napi_get_value_int32(env, args[1], &rows);
    g_screen.resize(cols, rows);
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value vtFeed(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string data = getString(env, args[0]);
    feed(data.data(), data.size());
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value vtScreen(napi_env env, napi_callback_info) {
    const std::string text = screenText();
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

napi_value vtStatus(napi_env env, napi_callback_info) {
    const std::string text = screenStatus();
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

}  // namespace

// 由 ssh_napi.cpp 的 Init 调用，把 vt* 函数挂到同一个 NAPI 模块上
void RegisterVtFunctions(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"vtReset", nullptr, vtReset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtFeed", nullptr, vtFeed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtScreen", nullptr, vtScreen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vtStatus", nullptr, vtStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    g_screen.resize(80, 24);
}
