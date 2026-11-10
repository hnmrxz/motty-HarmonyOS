/* G1 第 2 级运行时探针：在 OHOS 上 dlopen Go 的 c-shared 库并调用导出函数。
 * 这是第 3 级（NAPI）之前最关键的未知：Go runtime 能否作为共享库在 musl 上完成初始化。
 * 构建：clang.exe -target x86_64-linux-ohos --sysroot=<native>/sysroot -D__MUSL__ -O1 -o loader loader.c -ldl
 */
#include <dlfcn.h>
#include <stdio.h>

typedef int (*add_fn)(int, int);
typedef char *(*str_fn)(void);

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "./libmottycore-x86_64.so";
    printf("=== go-c-shared loader probe ===\n");
    printf("library : %s\n", path);

    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        printf("dlopen  : FAIL %s\n", dlerror());
        printf("result  : FAIL\n");
        return 1;
    }
    printf("dlopen  : OK\n");

    add_fn add = (add_fn)dlsym(h, "MottyAdd");
    if (!add) {
        printf("dlsym   : FAIL MottyAdd %s\n", dlerror());
        printf("result  : FAIL\n");
        return 1;
    }
    int r = add(2, 3);
    printf("MottyAdd(2,3) = %d (%s)\n", r, r == 5 ? "CORRECT" : "WRONG");

    str_fn ver = (str_fn)dlsym(h, "MottyVersion");
    if (ver) {
        char *v = ver();
        printf("version : %s\n", v ? v : "(null)");
    }

    str_fn probe = (str_fn)dlsym(h, "MottyProbe");
    if (probe) {
        char *p = probe();
        printf("probe   : %s\n", p ? p : "(null)");
    }

    dlclose(h);
    printf("result  : %s\n", r == 5 ? "PASS" : "FAIL");
    return r == 5 ? 0 : 1;
}
