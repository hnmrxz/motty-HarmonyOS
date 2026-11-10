// ai_fixture.go —— 本地 AI 端点夹具
//
// 目的：AI 能力的最小可验收切片。真实产品要接的是外部模型服务（需要密钥与网络），
// 在没有密钥的环境里，唯一诚实的做法是：把**通路**（请求构造、超时、错误处理、结果呈现）
// 用本地 stub 端点验证到可断言的程度，并明确标注"模型质量未验证"。
//
// 端点约定（故意保持最小）：
//   POST /v1/ai  {"prompt": "<文本>"}
//   → 200 {"answer": "stub: <prompt 字符数> chars"}
//   GET  /v1/health → 200 {"ok": true}
//
// 反例：请求体非 JSON 或缺少 prompt 时返回 400，便于客户端验证错误分支。
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

type aiRequest struct {
	Prompt string `json:"prompt"`
}

type aiResponse struct {
	Answer string `json:"answer"`
}

// startAIFixture 在 addr 上起 HTTP 夹具；返回的 listener 交给调用方 Close。
func startAIFixture(addr string) (net.Listener, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/v1/ai", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"method"}`, http.StatusMethodNotAllowed)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, `{"error":"read"}`, http.StatusBadRequest)
			return
		}
		var req aiRequest
		if err := json.Unmarshal(body, &req); err != nil || strings.TrimSpace(req.Prompt) == "" {
			http.Error(w, `{"error":"bad request"}`, http.StatusBadRequest)
			return
		}
		resp := aiResponse{Answer: fmt.Sprintf("stub: %d chars", len([]rune(req.Prompt)))}
		out, _ := json.Marshal(resp)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(out)
	})
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("ai fixture: serve ended: %v", err)
		}
	}()
	log.Printf("ai fixture listening on %s", addr)
	return ln, nil
}
