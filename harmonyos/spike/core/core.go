// G1 第 2 级探针：把 Go 编成 OHOS 可加载的共享库（c-shared）。
// 构建（模拟器目标 x86_64）：
//   CGO_ENABLED=1 GOOS=linux GOARCH=amd64 ^
//   CC="<NDK>\llvm\bin\x86_64-unknown-linux-ohos-clang" ^
//   go build -buildmode=c-shared -o libmottycore.so .
package main

import "C"

import "fmt"

//export MottyAdd
func MottyAdd(a, b C.int) C.int { return a + b }

//export MottyVersion
func MottyVersion() *C.char { return C.CString("motty-core-ohos-0.0.1") }

//export MottyProbe
func MottyProbe() *C.char {
	// 在共享库语境下做一次最小运行时自检，返回值交给 ArkTS 展示
	return C.CString(fmt.Sprintf("goroutines-ok go=%s", "1.27"))
}

func main() {}
