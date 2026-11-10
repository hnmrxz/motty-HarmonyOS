// sshfixture：Windows/无 pty 环境下可用的最小 SSH 对端。
//
// 为什么需要它：仓库里的 tools/e2esshd 依赖 /bin/bash 与真 pty（creack/pty），
// 在 Windows 宿主上起不来，本机也没有 WSL/Docker。而 B1 批次（主机与认证）里
// 有一部分 spec 只需要"能连上、能认证、能跑一条命令"，不需要 pty 语义。
//
// 明确的能力边界（不要用它冒充 e2esshd）：
//   ✔ 主机密钥（持久化文件，便于 known_hosts 与 hostkey 变更测试）
//   ✔ 密码认证（任意用户 / 密码 secret）
//   ✔ 公钥认证（启动时生成 ed25519，打印路径与指纹）
//   ✔ exec 请求（不需要 pty）：echo、以及一个固定的 banner
//   ✔ 拒绝 pty-req / shell 请求，并明确报错——这样 pty 相关 spec 会响亮失败，
//     而不是悄悄"通过"一个假的 pty
//   ✘ 没有 SFTP / SCP / 转发 / X11 —— 那些仍然要找 Linux 对端
//
// 用法：
//   go run ./tools/design/sshfixture -addr 127.0.0.1:2222 -hostkey ./.sshfixture/hostkey
package main

import (
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/rand"
	"crypto/subtle"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:2222", "listen address (loopback only by default)")
	hostkeyPath := flag.String("hostkey", "", "persistent host key path (empty = generate every start)")
	hostkeyType := flag.String("hostkeytype", "rsa", "host key type: rsa (widest interop) or ed25519")
	user := flag.String("user", "tester", "only this user is accepted")
	pass := flag.String("password", "secret", "password for password auth")
	printKey := flag.Bool("print-client-key", true, "print the generated client key path/passphrase")
	flag.Parse()

	if err := run(*addr, *hostkeyPath, *hostkeyType, *user, *pass, *printKey); err != nil {
		log.Fatalf("sshfixture: %v", err)
	}
}

func run(addr, hostkeyPath, hostkeyType, user, pass string, printKey bool) error {
	hostSigner, _, err := loadOrCreateHostKey(hostkeyPath, hostkeyType)
	if err != nil {
		return fmt.Errorf("host key: %w", err)
	}

	clientPub, clientKeyPath, err := createClientKey()
	if err != nil {
		return fmt.Errorf("client key: %w", err)
	}

	cfg := &ssh.ServerConfig{
		PasswordCallback: func(c ssh.ConnMetadata, p []byte) (*ssh.Permissions, error) {
			if c.User() != user {
				return nil, fmt.Errorf("unknown user %q", c.User())
			}
			if subtle.ConstantTimeCompare(p, []byte(pass)) != 1 {
				return nil, fmt.Errorf("bad password for %q", c.User())
			}
			return &ssh.Permissions{Extensions: map[string]string{"auth": "password"}}, nil
		},
		PublicKeyCallback: func(c ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if c.User() != user {
				return nil, fmt.Errorf("unknown user %q", c.User())
			}
			if subtle.ConstantTimeCompare(key.Marshal(), clientPub.Marshal()) != 1 {
				return nil, fmt.Errorf("unknown public key")
			}
			return &ssh.Permissions{Extensions: map[string]string{"auth": "publickey"}}, nil
		},
	}
	cfg.AddHostKey(hostSigner)

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}
	defer ln.Close()

	fmt.Printf("sshfixture listening on %s\n", ln.Addr().String())
	fmt.Printf("host key fingerprint : %s\n", ssh.FingerprintSHA256(hostSigner.PublicKey()))
	fmt.Printf("accepted user        : %s (password: %s)\n", user, pass)
	if printKey {
		fmt.Printf("client key           : %s (passphrase: key-secret)\n", clientKeyPath)
	}
	fmt.Printf("client key fingerprint: %s\n", ssh.FingerprintSHA256(clientPub))
	os.Stdout.Sync()

	for {
		conn, err := ln.Accept()
		if err != nil {
			return err
		}
		go handle(conn, cfg)
	}
}

func handle(conn net.Conn, cfg *ssh.ServerConfig) {
	defer conn.Close()
	sconn, chans, reqs, err := ssh.NewServerConn(conn, cfg)
	if err != nil {
		log.Printf("handshake failed: %v", err)
		return
	}
	auth := sconn.Permissions.Extensions["auth"]
	log.Printf("session from %s user=%s auth=%s", conn.RemoteAddr(), sconn.User(), auth)

	go ssh.DiscardRequests(reqs)
	for newCh := range chans {
		if newCh.ChannelType() != "session" {
			_ = newCh.Reject(ssh.UnknownChannelType, "only session channels are supported")
			continue
		}
		ch, chReqs, err := newCh.Accept()
		if err != nil {
			continue
		}
		go serveSession(ch, chReqs, auth)
	}
}

func serveSession(ch ssh.Channel, reqs <-chan *ssh.Request, auth string) {
	defer ch.Close()
	for req := range reqs {
		switch req.Type {
		case "exec":
			var payload struct{ Command string }
			if err := ssh.Unmarshal(req.Payload, &payload); err != nil {
				req.Reply(false, nil)
				continue
			}
			req.Reply(true, nil)
			log.Printf("exec: %q", payload.Command)
			if strings.HasPrefix(payload.Command, "term-demo") {
				// 多行 + 延迟：终端渲染/流式接收的验证用。刻意带 \r\n 与转义序列，
				// 让后续真正的 VT 解析有东西可吃。
				fmt.Fprint(ch, "term-line-1 start\r\n")
				for i := 2; i <= 5; i++ {
					time.Sleep(120 * time.Millisecond)
					fmt.Fprintf(ch, "term-line-%d\r\n", i)
				}
				fmt.Fprint(ch, "\x1b[32mterm-line-6 green\x1b[0m\r\n")
			} else {
				// 固定、可断言的输出：让 spec 能判断"命令真的在远端执行了"
				fmt.Fprintf(ch, "fixture-exec-ok auth=%s\n", auth)
				fmt.Fprintf(ch, "command=%s\n", payload.Command)
			}
			status := struct{ Status uint32 }{0}
			ch.SendRequest("exit-status", false, ssh.Marshal(&status))
			return
		case "pty-req":
			// 刻意拒绝：没有 Windows pty 就先明说，别让 pty 相关 spec 假通过
			req.Reply(false, nil)
			log.Printf("pty-req refused (no pty on this fixture)")
		case "shell":
			req.Reply(false, nil)
			log.Printf("shell refused (no pty on this fixture)")
			fmt.Fprint(ch, "sshfixture: interactive shell is not supported; use exec\n")
			status := struct{ Status uint32 }{1}
			ch.SendRequest("exit-status", false, ssh.Marshal(&status))
			return
		default:
			req.Reply(false, nil)
		}
	}
}

func loadOrCreateHostKey(path, keyType string) (ssh.Signer, string, error) {
	if path != "" {
		if b, err := os.ReadFile(path); err == nil {
			s, err := ssh.ParsePrivateKey(b)
			if err != nil {
				return nil, "", err
			}
			return s, path, nil
		}
	}
	// 默认 RSA-3072：libssh2 + mbedTLS 后端的算法覆盖远窄于 OpenSSL 构建，
	// ed25519 主机密钥在部分组合下协商不上（实测 "Unable to exchange encryption keys"）。
	var priv any
	var err error
	if strings.EqualFold(keyType, "ed25519") {
		_, priv, err = ed25519.GenerateKey(rand.Reader)
	} else {
		rsaKey, gerr := rsa.GenerateKey(rand.Reader, 3072)
		priv, err = rsaKey, gerr
	}
	if err != nil {
		return nil, "", err
	}
	block, err := ssh.MarshalPrivateKey(priv, "")
	if err != nil {
		return nil, "", err
	}
	if path != "" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, "", err
		}
		if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o600); err != nil {
			return nil, "", err
		}
	}
	s, err := ssh.NewSignerFromKey(priv)
	return s, path, err
}

func createClientKey() (ssh.PublicKey, string, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, "", err
	}
	// 客户端私钥用带口令的 OpenSSH 格式，方便以后测"私钥口令"路径
	block, err := ssh.MarshalPrivateKeyWithPassphrase(priv, "", []byte("key-secret"))
	if err != nil {
		return nil, "", err
	}
	dir, err := os.MkdirTemp("", "sshfixture-client-*")
	if err != nil {
		return nil, "", err
	}
	path := filepath.Join(dir, "id_ed25519")
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o600); err != nil {
		return nil, "", err
	}
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		return nil, "", err
	}
	// 顺手把公钥写出来，便于宿主侧 ssh 客户端验证
	if err := os.WriteFile(path+".pub", []byte(strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sshPub)))+"\n"), 0o644); err != nil {
		return nil, "", err
	}
	return sshPub, path, nil
}
