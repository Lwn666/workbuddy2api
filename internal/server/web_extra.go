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

// WrapWeb 包装上游 handler：前端请求（/、/web/*）就地响应，其余转发给 next。
// 仅当启用时（enabled）生效；不启用则原样返回 next。
// 返回 http.Handler（保持接口通用，main.go 用新变量接收）。
func WrapWeb(next http.Handler, enabled bool) http.Handler {
	if !enabled {
		return next
	}
	fileServer := http.FileServer(http.FS(webSub))
	// 精确匹配："/" 根与 "/web/"、"web/…" 前缀属于前端；其余（/status /v1/... /healthz）转上游。
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
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
			// /web/* 静态资源
			fileServer.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
