// B′ 决定性探针：在「应用沙箱内」用 posix_spawn 启动随包分发的静态 Go 二进制。
// 若这条能通，Go 内核可以"子进程 + 管道"的方式救回来（B′）；
// 若被 seccomp/沙箱拒绝，Go 内核在鸿蒙应用内就彻底不可用，只能走 A（全量 ArkTS）。
#include <napi/native_api.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace {

std::string SpawnAndCapture(const char *path, int *exitCode) {
    *exitCode = -1;
    std::string pre;

    // 0) 报告真实权限（bundle 目录只读，安装后的 .so 通常已是 0755）
    struct stat st;
    if (stat(path, &st) == 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "stat: mode=0%o size=%lld\n", static_cast<unsigned>(st.st_mode),
                 static_cast<long long>(st.st_size));
        pre += buf;
    } else {
        pre += std::string("stat failed: ") + std::strerror(errno) + "\n";
    }

    // 1) 可执行位：尽力而为，失败不阻断（只读目录下改不了权限，但可能本来就够）
    if (chmod(path, 0755) != 0) {
        pre += std::string("chmod (best effort): ") + std::strerror(errno) + "\n";
    }

    // 2) 管道捕获 stdout/stderr
    int fds[2];
    if (pipe(fds) != 0) {
        return pre + "pipe failed: " + std::strerror(errno);
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    char *argv[] = {const_cast<char *>(path), nullptr};
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, &actions, nullptr, argv, environ);

    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);

    if (rc != 0) {
        close(fds[0]);
        return pre + "posix_spawn failed: rc=" + std::to_string(rc) + " " + std::strerror(rc);
    }

    std::string out;
    char buf[512];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof(buf))) > 0) {
        out.append(buf, static_cast<size_t>(n));
    }
    close(fds[0]);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return pre + out + "\nwaitpid failed: " + std::strerror(errno);
    }
    if (WIFEXITED(status)) {
        *exitCode = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        out += "\n[signalled: " + std::to_string(WTERMSIG(status)) + "]";
        *exitCode = -2;
    }
    return pre + out;
}

napi_value Run(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char path[1024] = {0};
    size_t pathLen = 0;
    if (argc < 1 || napi_get_value_string_utf8(env, args[0], path, sizeof(path), &pathLen) != napi_ok) {
        napi_value err;
        napi_create_string_utf8(env, "argument must be a string path", NAPI_AUTO_LENGTH, &err);
        return err;
    }

    int code = -1;
    std::string out = SpawnAndCapture(path, &code);
    out += "\n[exit=" + std::to_string(code) + "]";

    napi_value result;
    napi_create_string_utf8(env, out.c_str(), out.size(), &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"run", nullptr, Run, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

static napi_module bprobeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "bprobe",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterBProbeModule(void) {
    napi_module_register(&bprobeModule);
}
