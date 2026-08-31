// Package login 封装 WorkBuddy CN 的 OAuth 设备流（与 cmd/login 一致），
// 供服务端 Web 登录接口与落盘使用。仅支持 region=cn（与上游 CLI 一致）。
package login

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"os"
	"path/filepath"
	"time"
)

const (
	upstreamBaseCN = "https://copilot.tencent.com"
	clientUA       = "CLI/2.63.2 CodeBuddy/2.63.2"
	originReferer  = "https://www.codebuddy.cn"

	endpointAuthState = upstreamBaseCN + "/v2/plugin/auth/state?platform=CLI"
	endpointAuthToken = upstreamBaseCN + "/v2/plugin/auth/token?state="
	endpointLoginAcct = upstreamBaseCN + "/v2/plugin/login/account?state="
)

// Bundle 登录成功后拿到的完整凭证。
type Bundle struct {
	AccessToken  string
	RefreshToken string
	ExpiresIn    int64
	Domain       string
	UID          string
	EnterpriseID string
	Nickname     string
	ExpiresAt    int64 // Unix 秒，由 ExpiresIn 推导
}

type apiEnvelope struct {
	Code int             `json:"code"`
	Msg  string          `json:"msg"`
	Data json.RawMessage `json:"data"`
}

func commonHeaders(req *http.Request) {
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	req.Header.Set("Origin", originReferer)
	req.Header.Set("Referer", originReferer+"/")
	req.Header.Set("User-Agent", clientUA)
}

func doJSON(client *http.Client, method, fullURL string, headers func(*http.Request), body io.Reader) (json.RawMessage, int, error) {
	req, err := http.NewRequest(method, fullURL, body)
	if err != nil {
		return nil, 0, err
	}
	if headers != nil {
		headers(req)
	} else {
		commonHeaders(req)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, resp.StatusCode, fmt.Errorf("http_error: upstream %d", resp.StatusCode)
	}
	var env apiEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, resp.StatusCode, fmt.Errorf("parse failed: %w", err)
	}
	if env.Code != 0 {
		return nil, resp.StatusCode, fmt.Errorf("code=%d msg=%s", env.Code, env.Msg)
	}
	return env.Data, resp.StatusCode, nil
}

// Start 拿授权 URL + state。state 由调用方保管，传给 Poll。
func Start() (state, authURL string, err error) {
	jar, _ := cookiejar.New(nil)
	client := &http.Client{Timeout: 30 * time.Second, Jar: jar}
	data, _, err := doJSON(client, http.MethodPost, endpointAuthState, nil, bytes.NewReader([]byte("{}")))
	if err != nil {
		return "", "", fmt.Errorf("auth state failed: %w", err)
	}
	var st struct {
		State   string `json:"state"`
		AuthURL string `json:"authUrl"`
	}
	if err := json.Unmarshal(data, &st); err != nil || st.State == "" || st.AuthURL == "" {
		return "", "", fmt.Errorf("auth state: missing state or authUrl")
	}
	return st.State, st.AuthURL, nil
}

// Poll 用之前拿到的 state 轮询 token；pending 时返回 err 且 ok=false（调用方应继续轮询）。
// ok=true 表示登录完成，返回完整 Bundle。
func Poll(state string) (b *Bundle, ok bool, err error) {
	jar, _ := cookiejar.New(nil)
	client := &http.Client{Timeout: 30 * time.Second, Jar: jar}

	tokRaw, status, errTok := doJSON(client, http.MethodGet, endpointAuthToken+state, nil, nil)
	if errTok != nil {
		if status == 0 || status >= 500 {
			return nil, false, fmt.Errorf("token endpoint error: %w", errTok)
		}
		// 4xx / 业务错误（pending）：登录尚未完成
		return nil, false, nil
	}
	var tok struct {
		AccessToken  string `json:"accessToken"`
		RefreshToken string `json:"refreshToken"`
		ExpiresIn    int64  `json:"expiresIn"`
		Domain       string `json:"domain"`
	}
	if err := json.Unmarshal(tokRaw, &tok); err != nil || tok.AccessToken == "" {
		return nil, false, nil
	}

	b = &Bundle{
		AccessToken:  tok.AccessToken,
		RefreshToken: tok.RefreshToken,
		ExpiresIn:    tok.ExpiresIn,
		Domain:       tok.Domain,
		ExpiresAt:    time.Now().Add(time.Duration(tok.ExpiresIn) * time.Second).Unix(),
	}

	// login/account 拿 uid/nickname（带 Bearer）
	acctHeaders := func(r *http.Request) {
		commonHeaders(r)
		r.Header.Set("Authorization", "Bearer "+tok.AccessToken)
	}
	if acctRaw, _, errAcct := doJSON(client, http.MethodGet, endpointLoginAcct+state, acctHeaders, nil); errAcct == nil {
		var acct struct {
			UID          string `json:"uid"`
			EnterpriseID string `json:"enterpriseId"`
			Nickname     string `json:"nickname"`
		}
		if json.Unmarshal(acctRaw, &acct) == nil {
			b.UID = acct.UID
			b.EnterpriseID = acct.EnterpriseID
			b.Nickname = acct.Nickname
		}
	}
	if b.UID == "" {
		return nil, false, fmt.Errorf("login completed but uid empty")
	}
	return b, true, nil
}

// SaveToFile 将 Bundle 落盘为 auth_dir/workbuddy-<uid>.json（嵌套形，与 auth.Parse 一致）。
// 返回最终文件路径。
func (b *Bundle) SaveToFile(authDir string) (string, error) {
	if err := os.MkdirAll(authDir, 0o755); err != nil {
		return "", err
	}
	doc := map[string]any{
		"auth": map[string]any{
			"accessToken":  b.AccessToken,
			"refreshToken": b.RefreshToken,
			"expiresAt":    b.ExpiresAt,
			"domain":       b.Domain,
		},
		"account": map[string]any{
			"uid":          b.UID,
			"enterpriseId": b.EnterpriseID,
			"nickname":     b.Nickname,
		},
	}
	raw, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return "", err
	}
	fp := filepath.Join(authDir, "workbuddy-"+b.UID+".json")
	tmp := fp + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, fp); err != nil {
		return "", err
	}
	return fp, nil
}
