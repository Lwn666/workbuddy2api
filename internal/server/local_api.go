package server

import (
	"log"
	"net/http"

	"workbuddy2api/internal/auth"
	"workbuddy2api/internal/login"
	"workbuddy2api/internal/pool"
	"workbuddy2api/internal/upstream"
)

// LocalAPI 提供内置前端需要的本地 API（一键签到、扫码添加账号）。
// 设计为独立于上游 Handler 的结构：不修改 handler.go，全部代码在本文件，
// 由 WrapWeb 挂载路由，main.go 只传依赖。
type LocalAPI struct {
	Pool         *pool.Pool
	Upstream     *upstream.Client
	RunCheckin   func() // 触发一次签到轮（由 main 注入 scheduler.RunCheckinNow）
	AuthDir      string
	LoginEnabled bool
}

func NewLocalAPI(p *pool.Pool, up *upstream.Client, runCheckin func(), authDir string, loginEnabled bool) *LocalAPI {
	return &LocalAPI{
		Pool:         p,
		Upstream:     up,
		RunCheckin:   runCheckin,
		AuthDir:      authDir,
		LoginEnabled: loginEnabled,
	}
}

// handleCheckin 手动触发一次签到轮（同步执行；结果由 scheduler 推送）。
func (a *LocalAPI) handleCheckin(w http.ResponseWriter, r *http.Request) {
	if a.RunCheckin == nil {
		writeOpenAIError(w, http.StatusServiceUnavailable, "checkin_unavailable", "scheduler not available")
		return
	}
	a.RunCheckin()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": "签到已触发"})
}

// handleLoginStart 发起 OAuth 设备流，返回授权 URL 与 state。
func (a *LocalAPI) handleLoginStart(w http.ResponseWriter, r *http.Request) {
	if !a.LoginEnabled {
		writeOpenAIError(w, http.StatusForbidden, "login_disabled", "web login is disabled by config")
		return
	}
	state, authURL, err := login.Start()
	if err != nil {
		writeOpenAIError(w, http.StatusBadGateway, "login_start_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"state":    state,
		"auth_url": authURL,
	})
}

// handleLoginPoll 用 state 轮询登录结果；pending 时返回 {pending:true}。
func (a *LocalAPI) handleLoginPoll(w http.ResponseWriter, r *http.Request) {
	if !a.LoginEnabled {
		writeOpenAIError(w, http.StatusForbidden, "login_disabled", "web login is disabled by config")
		return
	}
	state := r.URL.Query().Get("state")
	if state == "" {
		writeOpenAIError(w, http.StatusBadRequest, "bad_request", "missing state")
		return
	}
	bundle, ok, err := login.Poll(state)
	if err != nil {
		writeOpenAIError(w, http.StatusBadGateway, "login_poll_failed", err.Error())
		return
	}
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"pending": true})
		return
	}

	fp, err := bundle.SaveToFile(a.AuthDir)
	if err != nil {
		writeOpenAIError(w, http.StatusInternalServerError, "save_failed", "save auth: "+err.Error())
		return
	}

	// 加入账号池（带完整凭证，供后续 refresh 写回）
	acc := &auth.Auth{
		AccessToken:  bundle.AccessToken,
		RefreshToken: bundle.RefreshToken,
		ExpiresAt:    bundle.ExpiresAt,
		Domain:       bundle.Domain,
		UID:          bundle.UID,
		EnterpriseID: bundle.EnterpriseID,
		Nickname:     bundle.Nickname,
		FilePath:     fp,
	}
	a.Pool.Add(acc)

	// 立即查询一次积分（非阻塞，失败忽略）
	if remain, rerr := a.Upstream.UserResource(acc); rerr == nil {
		a.Pool.SetCredits(acc.UID, remain)
	}

	log.Printf("web login success: uid=%s nickname=%s file=%s", acc.UID, acc.Nickname, fp)
	writeJSON(w, http.StatusOK, map[string]any{
		"pending":  false,
		"uid":      acc.UID,
		"nickname": acc.Nickname,
		"file":     fp,
	})
}
