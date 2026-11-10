// vt_core.cpp —— 终端网格核心（基于 libvterm，MIT）
//
// 为什么换成 libvterm：之前这份文件里我手写了一个"最小 VT"，代价是宽度近似、
// 序列覆盖不全、宽字符/备用屏都是自己猜的。libvterm 是成熟实现（Neovim/Vim 在用），
// MIT 许可，可交叉编译到 OHOS，且没有 perl 依赖（.inc 表已随仓库提供）。
//
// 保留自研的部分：**回滚缓冲**（libvterm 不提供），以及把网格导出成文本/状态字符串
// 的观测面（vtScreen/vtStatus），因为 spec 需要机器可判定的输出。
//
// 对外 NAPI 与之前保持一致：vtNew/vtFree/vtReset/vtFeed/vtScreen/vtStatus/vtScrollBack。
#include <napi/native_api.h>
#include <vterm.h>

#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr int kMaxCols = 400;
constexpr int kMaxRows = 200;
constexpr size_t kMaxHistory = 2000;

struct Screen {
    VTerm *vt = nullptr;
    VTermScreen *vts = nullptr;
    VTermState *state = nullptr;
    int cols = 80;
    int rows = 24;

    // 回滚缓冲：libvterm 的回调把"被顶出的整行"交给我们
    std::vector<std::string> history;
    bool altActive = false;

    // 备用屏切换与滚动通知（libvterm 通过回调告诉我们是"进/出备用屏"）
    bool inAlt = false;
};

std::map<int, Screen *> g_screens;
int g_nextScreenId = 1;
std::mutex g_mtx;

// UTF-8 编码（单个码点）
void appendUtf8(std::string &out, uint32_t cp) {
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
}

// 把一行 cells 转成文本（去掉行尾空格）
std::string rowText(Screen &s, int row) {
    std::string line;
    for (int col = 0; col < s.cols; col++) {
        VTermPos pos{row, col};
        VTermScreenCell cell{};
        if (!vterm_screen_get_cell(s.vts, pos, &cell)) {
            line.push_back(' ');
            continue;
        }
        if (cell.width == 2) {
            if (cell.chars[0] != 0) {
                appendUtf8(line, cell.chars[0]);
            }
            col++;   // 宽字符占两列：跳过右侧续格
            continue;
        }
        if (cell.chars[0] == 0) {
            line.push_back(' ');
        } else {
            for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i] != 0; i++) {
                appendUtf8(line, cell.chars[i]);
            }
        }
    }
    while (!line.empty() && line.back() == ' ') {
        line.pop_back();
    }
    return line;
}

// ---- libvterm 回调：回滚与备用屏 ----
int cbSbPushline(int cols, const VTermScreenCell *cells, void *user) {
    auto *s = static_cast<Screen *>(user);
    if (s == nullptr || s->inAlt) {
        return 1;
    }
    std::string line;
    for (int i = 0; i < cols; i++) {
        if (cells[i].width == 2) {
            if (cells[i].chars[0] != 0) {
                appendUtf8(line, cells[i].chars[0]);
            }
            i++;
            continue;
        }
        if (cells[i].chars[0] == 0) {
            line.push_back(' ');
        } else {
            for (int k = 0; k < VTERM_MAX_CHARS_PER_CELL && cells[i].chars[k] != 0; k++) {
                appendUtf8(line, cells[i].chars[k]);
            }
        }
    }
    while (!line.empty() && line.back() == ' ') {
        line.pop_back();
    }
    s->history.push_back(line);
    if (s->history.size() > kMaxHistory) {
        s->history.erase(s->history.begin());
    }
    return 1;
}

int cbSbPopline(int cols, VTermScreenCell *cells, void *user) {
    (void)cols;
    (void)cells;
    (void)user;
    return 0;   // 不回放（没有"向上滚动"的 UI 交互）
}

int cbSettermprop(VTermProp prop, VTermValue *val, void *user) {
    auto *s = static_cast<Screen *>(user);
    if (s != nullptr && prop == VTERM_PROP_ALTSCREEN) {
        s->inAlt = (val != nullptr && val->boolean != 0);
        s->altActive = s->inAlt;
    }
    // 必须返回 0：返回 1 表示"回调已处理"，libvterm 会跳过自己的备用屏切换，
    // 主屏内容就再也回不来了（实测：退出备用屏后主屏只剩最后一行）。
    return 0;
}

int cbResize(int rows, int cols, void *user) {
    auto *s = static_cast<Screen *>(user);
    if (s != nullptr && rows > 0 && cols > 0) {
        s->rows = rows;
        s->cols = cols;
    }
    return 0;   // 同样交给 libvterm 完成内部重排
}

VTermScreenCallbacks g_callbacks = {
    nullptr,      // damage
    nullptr,      // moverect
    nullptr,      // movecursor
    cbSettermprop,
    nullptr,      // bell
    cbResize,
    cbSbPushline,
    cbSbPopline,
};

void destroyScreen(Screen *s) {
    if (s == nullptr) {
        return;
    }
    if (s->vt != nullptr) {
        vterm_free(s->vt);
    }
    delete s;
}

Screen *createScreen(int cols, int rows) {
    auto *s = new Screen();
    s->cols = cols < 8 ? 8 : (cols > kMaxCols ? kMaxCols : cols);
    s->rows = rows < 4 ? 4 : (rows > kMaxRows ? kMaxRows : rows);
    s->vt = vterm_new(s->rows, s->cols);
    if (s->vt == nullptr) {
        delete s;
        return nullptr;
    }
    vterm_set_utf8(s->vt, 1);
    s->vts = vterm_obtain_screen(s->vt);
    s->state = vterm_obtain_state(s->vt);
    vterm_screen_set_callbacks(s->vts, &g_callbacks, s);
    // 备用屏必须在 screen 层显式启用，否则 1049 只会发 settermprop 通知，
    // 不会真的切换缓冲——实测表现是"进备用屏后 \x1b[2J 把主屏也清了"。
    vterm_screen_enable_altscreen(s->vts, 1);
    vterm_screen_reset(s->vts, 1);
    return s;
}

Screen *screenOf(int id) {
    std::lock_guard<std::mutex> lock(g_mtx);
    auto it = g_screens.find(id);
    if (it == g_screens.end()) {
        return nullptr;
    }
    return it->second;
}

std::string screenText(Screen *s) {
    if (s == nullptr) {
        return std::string();
    }
    vterm_screen_flush_damage(s->vts);
    std::string out;
    for (int r = 0; r < s->rows; r++) {
        std::string line = rowText(*s, r);
        if (line.empty() && r == s->rows - 1) {
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

std::string screenStatus(Screen *s) {
    if (s == nullptr) {
        return std::string("vt: not found");
    }
    vterm_screen_flush_damage(s->vts);
    int colored = 0;
    int wide = 0;
    for (int r = 0; r < s->rows; r++) {
        for (int c = 0; c < s->cols; c++) {
            VTermPos pos{r, c};
            VTermScreenCell cell{};
            if (!vterm_screen_get_cell(s->vts, pos, &cell)) {
                continue;
            }
            if (cell.chars[0] != 0 && !VTERM_COLOR_IS_DEFAULT_FG(&cell.fg)) {
                colored++;
            }
            if (cell.width == 2) {
                wide++;
            }
        }
    }
    VTermPos cur{0, 0};
    if (s->state != nullptr) {
        vterm_state_get_cursorpos(s->state, &cur);
    }
    char buf[192];
    snprintf(buf, sizeof(buf), "cur=%d,%d colors=%d wide=%d hist=%d alt=%d size=%dx%d",
             cur.row + 1, cur.col + 1, colored, wide,
             static_cast<int>(s->history.size()), s->altActive ? 1 : 0, s->cols, s->rows);
    return std::string(buf);
}

std::string historyTail(Screen *s, int n) {
    if (s == nullptr || n <= 0 || s->history.empty()) {
        return std::string();
    }
    const size_t total = s->history.size();
    const size_t take = static_cast<size_t>(n) < total ? static_cast<size_t>(n) : total;
    std::string out;
    for (size_t i = total - take; i < total; i++) {
        out += s->history[i];
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

// ---- NAPI ----
Screen &defaultScreen() {
    static Screen *s = nullptr;
    if (s == nullptr) {
        s = createScreen(80, 24);
        std::lock_guard<std::mutex> lock(g_mtx);
        g_screens[0] = s;
    }
    return *s;
}

napi_value vtNew(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t cols = 80;
    int32_t rows = 24;
    if (argc > 0) napi_get_value_int32(env, args[0], &cols);
    if (argc > 1) napi_get_value_int32(env, args[1], &rows);
    Screen *s = createScreen(cols, rows);
    int id = 0;
    if (s != nullptr) {
        std::lock_guard<std::mutex> lock(g_mtx);
        id = g_nextScreenId++;
        g_screens[id] = s;
    }
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
    Screen *s = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        auto it = g_screens.find(id);
        if (it != g_screens.end() && id != 0) {
            s = it->second;
            g_screens.erase(it);
        }
    }
    int freed = 0;
    if (s != nullptr) {
        destroyScreen(s);
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
    Screen *s = (argc >= 3) ? screenOf(id) : &defaultScreen();
    if (s != nullptr) {
        vterm_set_size(s->vt, rows, cols);
        s->rows = rows;
        s->cols = cols;
        vterm_screen_reset(s->vts, 1);
        s->history.clear();
        s->altActive = false;
        s->inAlt = false;
    }
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value vtFeed(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    Screen *s = nullptr;
    std::string data;
    if (argc >= 2) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        data = getString(env, args[1]);
        s = screenOf(id);
    } else {
        data = getString(env, args[0]);
        s = &defaultScreen();
    }
    if (s != nullptr && !data.empty()) {
        vterm_input_write(s->vt, data.data(), data.size());
        vterm_screen_flush_damage(s->vts);
    }
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value vtScreen(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    Screen *s = nullptr;
    if (argc >= 1) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        s = screenOf(id);
    } else {
        s = &defaultScreen();
    }
    const std::string text = screenText(s);
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

napi_value vtStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    Screen *s = nullptr;
    if (argc >= 1) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        s = screenOf(id);
    } else {
        s = &defaultScreen();
    }
    const std::string text = screenStatus(s);
    napi_value out = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &out);
    return out;
}

napi_value vtScrollBack(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    Screen *s = nullptr;
    int32_t n = 5;
    if (argc >= 2) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        napi_get_value_int32(env, args[1], &n);
        s = screenOf(id);
    } else {
        if (argc >= 1) napi_get_value_int32(env, args[0], &n);
        s = &defaultScreen();
    }
    const std::string text = historyTail(s, n);
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
