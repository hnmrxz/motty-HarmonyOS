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
	"io"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

var sftpRoot string

func main() {
	addr := flag.String("addr", "127.0.0.1:2222", "listen address (loopback only by default)")
	hostkeyPath := flag.String("hostkey", "", "persistent host key path (empty = generate every start)")
	hostkeyType := flag.String("hostkeytype", "rsa", "host key type: rsa (widest interop) or ed25519")
	user := flag.String("user", "tester", "only this user is accepted")
	pass := flag.String("password", "secret", "password for password auth")
	vncAddr := flag.String("vnc", "127.0.0.1:5901", "VNC(RFB) fixture listen address")
	printKey := flag.Bool("print-client-key", true, "print the generated client key path/passphrase")
	flag.Parse()

	if err := run(*addr, *hostkeyPath, *hostkeyType, *user, *pass, *vncAddr, *printKey); err != nil {
		log.Fatalf("sshfixture: %v", err)
	}
}

func run(addr, hostkeyPath, hostkeyType, user, pass, vncAddr string, printKey bool) error {
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

	if _, verr := startRFBFixture(vncAddr); verr != nil {
		log.Printf("rfb fixture disabled: %v", verr)
	}

	var sftpErr error
	sftpRoot, sftpErr = prepareSftpRoot()
	if sftpErr != nil {
		log.Fatalf("prepare sftp root: %v", sftpErr)
	}
	log.Printf("sftp root: %s", sftpRoot)

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
		if newCh.ChannelType() == "direct-tcpip" {
			// 端口转发的对端：Go 的 ssh 库不实现转发，这里自己接。
			// 载荷是 {目标主机, 目标端口, 来源主机, 来源端口}，随后双向 io.Copy。
			go func(nc ssh.NewChannel) {
				var payload struct {
					Host       string
					Port       uint32
					OriginHost string
					OriginPort uint32
				}
				if err := ssh.Unmarshal(nc.ExtraData(), &payload); err != nil {
					_ = nc.Reject(ssh.Prohibited, "bad direct-tcpip payload")
					return
				}
				target := fmt.Sprintf("%s:%d", payload.Host, payload.Port)
				tconn, derr := net.DialTimeout("tcp", target, 5*time.Second)
				if derr != nil {
					log.Printf("direct-tcpip dial %s failed: %v", target, derr)
					_ = nc.Reject(ssh.ConnectionFailed, "dial failed")
					return
				}
				fch, freq, aerr := nc.Accept()
				if aerr != nil {
					_ = tconn.Close()
					return
				}
				go ssh.DiscardRequests(freq)
				log.Printf("direct-tcpip open -> %s", target)
				done := make(chan struct{}, 2)
				go func() { _, _ = io.Copy(tconn, fch); done <- struct{}{} }()
				go func() { _, _ = io.Copy(fch, tconn); done <- struct{}{} }()
				<-done
				_ = fch.Close()
				_ = tconn.Close()
				log.Printf("direct-tcpip closed -> %s", target)
			}(newCh)
			continue
		}
		if newCh.ChannelType() != "session" {
			_ = newCh.Reject(ssh.UnknownChannelType, "only session/direct-tcpip channels are supported")
			continue
		}
		ch, chReqs, err := newCh.Accept()
		if err != nil {
			continue
		}
		go serveSession(ch, chReqs, auth)
	}
}

// sftpRoot 是 SFTP 子系统的根目录。启动时准备一个已知文件，供 spec 断言。
func prepareSftpRoot() (string, error) {
	dir, err := os.MkdirTemp("", "motty-sftp-")
	if err != nil {
		return "", err
	}
	if werr := os.WriteFile(filepath.Join(dir, "hello.txt"),
		[]byte("sftp-hello-marker\n"), 0o644); werr != nil {
		return "", werr
	}
	sub := filepath.Join(dir, "sub")
	if merr := os.MkdirAll(sub, 0o755); merr != nil {
		return "", merr
	}
	if werr := os.WriteFile(filepath.Join(sub, "nested.txt"),
		[]byte("sftp-nested-marker\n"), 0o644); werr != nil {
		return "", werr
	}
	return dir, nil
}

func serveSession(ch ssh.Channel, reqs <-chan *ssh.Request, auth string) {
	defer ch.Close()
	var ptyWanted bool
	ptyCols, ptyRows := 80, 24
	var session *ptySession
	defer func() {
		if session != nil {
			session.Close()
		}
	}()
	for req := range reqs {
		switch req.Type {
		case "exec":
			if session != nil {
				// 同一通道上 pty 与 exec 混用没有意义，明确拒绝而不是含糊执行
				req.Reply(false, nil)
				log.Printf("exec refused: pty session already active")
				continue
			}
			var payload struct{ Command string }
			if err := ssh.Unmarshal(req.Payload, &payload); err != nil {
				req.Reply(false, nil)
				continue
			}
			req.Reply(true, nil)
			log.Printf("exec: %q", payload.Command)
			if strings.HasPrefix(payload.Command, "vt-demo2") {
				// 回滚：30 行 > 24 行屏幕，前面几行必须进历史缓冲
				for i := 1; i <= 30; i++ {
					fmt.Fprintf(ch, "scroll-%02d\r\n", i)
				}
				// 备用屏：进入后写标记，退出后该标记必须消失
				fmt.Fprint(ch, "\x1b[?1049h")
				fmt.Fprint(ch, "\x1b[2J\x1b[H")
				fmt.Fprint(ch, "alt-marker\r\n")
				fmt.Fprint(ch, "\x1b[?1049l")
				fmt.Fprint(ch, "main-after-alt\r\n")
				status := struct{ Status uint32 }{0}
				ch.SendRequest("exit-status", false, ssh.Marshal(&status))
				return
			}
			if strings.HasPrefix(payload.Command, "vt-demo") {
				// 最小 VT 子集的验收脚本：清屏、定位、颜色、擦行、跨行移动
				fmt.Fprint(ch, "\x1b[2J")            // 清屏
				fmt.Fprint(ch, "\x1b[1;1Hvt-line-1")  // 第 1 行第 1 列
				fmt.Fprint(ch, "\x1b[3;5Hvt-moved")   // 第 3 行第 5 列
				fmt.Fprint(ch, "\x1b[31mred-text\x1b[0m") // 红色后重置
				fmt.Fprint(ch, "\x1b[4;1Hvt-erase-me")
				fmt.Fprint(ch, "\x1b[4;1H\x1b[2K")   // 擦掉第 4 行
				fmt.Fprint(ch, "\x1b[10;1Hvt-line-10") // 跨到第 10 行
				fmt.Fprint(ch, "\x1b[1;1Hcursor-here") // 光标回到 1,1 覆盖写入
				// CJK 宽字符：终端是固定网格，汉字占 2 列；按 1 列存会与真实终端错位
				fmt.Fprint(ch, "\x1b[20;1H中文宽字符测试")
				fmt.Fprint(ch, "\x1b[21;1Habc|中文|def")
				status := struct{ Status uint32 }{0}
				ch.SendRequest("exit-status", false, ssh.Marshal(&status))
				return
			}
			if strings.HasPrefix(payload.Command, "term-echo") {
				// 交互式会话夹具：读完一行回一行，用来验证"键盘输入 -> 远端 -> 回显"闭环。
				fmt.Fprint(ch, "term-echo ready\r\n")
				buf := make([]byte, 256)
				for {
					n, rerr := ch.Read(buf)
					if n > 0 {
						line := strings.TrimRight(string(buf[:n]), "\r\n")
						if line != "" {
							fmt.Fprintf(ch, "echo: %s\r\n", line)
						}
					}
					if rerr != nil {
						break
					}
				}
				status := struct{ Status uint32 }{0}
				ch.SendRequest("exit-status", false, ssh.Marshal(&status))
				return
			}
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
			var pr struct {
				Term                string
				Columns, Rows       uint32
				Width, Height       uint32
				Modes               string
			}
			if err := ssh.Unmarshal(req.Payload, &pr); err != nil {
				req.Reply(false, nil)
				continue
			}
			ptyCols, ptyRows = int(pr.Columns), int(pr.Rows)
			ptyWanted = true
			req.Reply(true, nil)
			log.Printf("pty-req term=%s size=%dx%d", pr.Term, ptyCols, ptyRows)
		case "window-change":
			var wc struct{ Columns, Rows, Width, Height uint32 }
			if err := ssh.Unmarshal(req.Payload, &wc); err == nil {
				ptyCols, ptyRows = int(wc.Columns), int(wc.Rows)
				if session != nil {
					if rerr := session.Resize(ptyCols, ptyRows); rerr != nil {
						log.Printf("window-change resize failed: %v", rerr)
					} else {
						log.Printf("window-change -> %dx%d", ptyCols, ptyRows)
					}
				}
				req.Reply(true, nil)
			} else {
				req.Reply(false, nil)
			}
		case "subsystem":
			var sub struct{ Name string }
			_ = ssh.Unmarshal(req.Payload, &sub)
			if sub.Name != "sftp" || sftpRoot == "" {
				req.Reply(false, nil)
				log.Printf("subsystem %q refused", sub.Name)
				continue
			}
			req.Reply(true, nil)
			log.Printf("sftp subsystem started, root=%s", sftpRoot)
			srv, serr := sftp.NewServer(ch, sftp.WithServerWorkingDirectory(sftpRoot))
			if serr != nil {
				log.Printf("sftp server init failed: %v", serr)
				return
			}
			if serr := srv.Serve(); serr != nil && serr != io.EOF {
				log.Printf("sftp server ended: %v", serr)
			}
			_ = srv.Close()
			return
		case "shell":
			if session != nil {
				req.Reply(false, nil)
				continue
			}
			if !ptyWanted {
				req.Reply(false, nil)
				fmt.Fprint(ch, "sshfixture: shell requires a pty\n")
				status := struct{ Status uint32 }{1}
				ch.SendRequest("exit-status", false, ssh.Marshal(&status))
				return
			}
			st, serr := startPty(ptyCols, ptyRows)
			if serr != nil {
				req.Reply(false, nil)
				log.Printf("pty start failed: %v", serr)
				status := struct{ Status uint32 }{1}
				ch.SendRequest("exit-status", false, ssh.Marshal(&status))
				return
			}
			session = st
			req.Reply(true, nil)
			log.Printf("shell started on pty %dx%d", ptyCols, ptyRows)
			// pty -> 客户端
			go func() {
				buf := make([]byte, 4096)
				for {
					n, rerr := session.Read(buf)
					if n > 0 {
						if _, werr := ch.Write(buf[:n]); werr != nil {
							return
						}
					}
					if rerr != nil {
						break
					}
				}
			}()
			// 客户端 -> pty（阻塞读，直到通道关闭）
			go func() {
				buf := make([]byte, 4096)
				for {
					n, rerr := ch.Read(buf)
					if n > 0 {
						if _, werr := session.Write(buf[:n]); werr != nil {
							return
						}
					}
					if rerr != nil {
						break
					}
				}
			}()
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
