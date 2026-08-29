// Package server 前端扩展：嵌入静态资源 + 根路径路由。
// 本文件是本地新增（上游无此文件），全量同步上游时不会被覆盖。
package server

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"
)

//go:embed all:web
var webFS embed.FS

// webSub 前端静态资源子文件系统。
var webSub, _ = fs.Sub(webFS, "web")

// WrapWeb 包装上游 handler：前端请求（/、/web/*）就地响应，
// 本地 API（/api/checkin、/api/login/*）由 LocalAPI 处理，其余转发给 next。
// enabled=false 时原样返回 next。
// 返回 http.Handler（保持接口通用，main.go 用新变量接收）。
func WrapWeb(next http.Handler, enabled bool, local *LocalAPI) http.Handler {
	if !enabled {
		return next
	}
	fileServer := http.FileServer(http.FS(webSub))
	// 精确匹配："/" 根与 "/web/"、"web/…" 前缀属于前端；"/api/*" 本地 API；其余转上游。
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		// 本地 API 路由（登录/签到，仅本地新增）
		if local != nil {
			switch {
			case r.Method == http.MethodPost && p == "/api/checkin":
				local.handleCheckin(w, r)
				return
			case r.Method == http.MethodPost && p == "/api/login/start":
				local.handleLoginStart(w, r)
				return
			case r.Method == http.MethodGet && p == "/api/login/poll":
				local.handleLoginPoll(w, r)
				return
			}
		}
		if p == "/" || strings.HasPrefix(p, "/web/") || p == "/web" {
			// /web 重定向到 /web/，避免相对路径错乱
			if p == "/web" {
				http.Redirect(w, r, "/web/", http.StatusMovedPermanently)
				return
			}
			if p == "/" {
				// 根路径直接返回 index.html
				data, err := fs.ReadFile(webSub, "index.html")
				if err != nil {
					http.Error(w, "web assets missing", http.StatusInternalServerError)
					return
				}
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write(data)
				return
			}
			// /web/* 静态资源（剥掉 /web 前缀再交给 FileServer）
			if p != "/web/" {
				r2 := r.Clone(r.Context())
				r2.URL.Path = strings.TrimPrefix(p, "/web")
				if r2.URL.Path == "" {
					r2.URL.Path = "/"
				}
				fileServer.ServeHTTP(w, r2)
				return
			}
			// /web/ 目录默认返回 index.html
			data, err := fs.ReadFile(webSub, "index.html")
			if err != nil {
				http.Error(w, "web assets missing", http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(data)
			return
		}
		next.ServeHTTP(w, r)
	})
}
