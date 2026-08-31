// WorkBuddy2API 前端（上游兼容版）— /status 展示 + 一键签到 + 扫码添加账号
(function () {
  "use strict";

  var $ = function (s) { return document.querySelector(s); };
  var key = localStorage.getItem("wb2a_key") || "";

  function toast(msg, isErr) {
    var t = $("#toast");
    t.textContent = msg;
    t.classList.remove("hidden");
    t.style.background = isErr ? "#d9534f" : "#27ae60";
    setTimeout(function () { t.classList.add("hidden"); }, 2600);
  }

  function api(path, opts) {
    var o = opts || {};
    o.headers = Object.assign({ "Content-Type": "application/json" }, o.headers);
    if (key) o.headers["Authorization"] = "Bearer " + key;
    return fetch(path, o);
  }

  // ---- API Key ----
  function bindKey() {
    $("#apikey").value = key;
    $("#saveKey").addEventListener("click", function () {
      key = $("#apikey").value.trim();
      localStorage.setItem("wb2a_key", key);
      toast("API Key 已保存");
      loadStatus();
    });
  }

  // ---- 一键签到 ----
  function bindCheckin() {
    $("#checkinBtn").addEventListener("click", function () {
      if (!key) { toast("请先输入 API Key", true); return; }
      $("#checkinBtn").disabled = true;
      api("/api/checkin", { method: "POST", body: "{}" })
        .then(function (r) {
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        })
        .then(function (d) { toast(d.message || "签到已触发"); setTimeout(loadStatus, 4000); })
        .catch(function (e) { toast("签到失败: " + e.message, true); })
        .finally(function () { $("#checkinBtn").disabled = false; });
    });
  }

  // ---- 扫码添加账号 ----
  var loginState = null;
  var loginTimer = null;

  function stopLogin() {
    if (loginTimer) { clearInterval(loginTimer); loginTimer = null; }
    loginState = null;
  }

  function showLogin(bundle) {
    $("#loginOverlay").classList.remove("hidden");
    var qr = $("#qrcode");
    qr.innerHTML = "";
    new QRCode(qr, {
      text: bundle.auth_url,
      width: 220,
      height: 220,
      correctLevel: QRCode.CorrectLevel.M
    });
    $("#loginTip").textContent = "请用 WorkBuddy/CodeBuddy 扫码，登录完成后自动添加";
    // 开始轮询
    loginTimer = setInterval(function () {
      api("/api/login/poll?state=" + encodeURIComponent(bundle.state))
        .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status)); })
        .then(function (d) {
          if (d.pending) return; // 继续等
          stopLogin();
          $("#loginOverlay").classList.add("hidden");
          toast("账号已添加: " + (d.nickname || d.uid));
          loadStatus();
        })
        .catch(function (e) {
          stopLogin();
          $("#loginOverlay").classList.add("hidden");
          toast("登录失败: " + e.message, true);
        });
    }, 3000);
  }

  function bindLogin() {
    $("#loginBtn").addEventListener("click", function () {
      if (!key) { toast("请先输入 API Key", true); return; }
      api("/api/login/start", { method: "POST", body: "{}" })
        .then(function (r) {
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        })
        .then(function (d) {
          if (!d.auth_url) throw new Error("未获取到授权地址");
          loginState = d;
          showLogin(d);
        })
        .catch(function (e) { toast("登录失败: " + e.message, true); });
    });
    $("#loginCancel").addEventListener("click", function () {
      stopLogin();
      $("#loginOverlay").classList.add("hidden");
    });
  }

  // ---- 渲染 ----
  function fmtTime(s) {
    if (!s || s.indexOf("0001-01-01") === 0) return "—";
    return s.replace("T", " ").replace("Z", "").slice(0, 19);
  }

  function render(data) {
    var accts = data.accounts || [];
    $("#stTotal").textContent = data.total != null ? data.total : accts.length;
    $("#stActive").textContent = data.healthy != null ? data.healthy : 0;
    $("#stCooling").textContent = data.cooling != null ? data.cooling : 0;
    $("#stDisabled").textContent = data.disabled != null ? data.disabled : 0;
    var sum = 0;
    accts.forEach(function (a) { sum += a.credits || 0; });
    $("#stCredits").textContent = sum;

    $("#stats").classList.remove("hidden");
    var box = $("#accts");
    box.innerHTML = "";
    if (accts.length === 0) {
      $("#accountsEmpty").classList.remove("hidden");
      return;
    }
    $("#accountsEmpty").classList.add("hidden");
    accts.forEach(function (a) {
      var st = a.disabled ? "disabled" : (a.cooling ? "cooling" : "active");
      var stText = a.disabled ? "禁用" : (a.cooling ? "冷却" : "可用");
      var div = document.createElement("div");
      div.className = "acct " + st;
      div.innerHTML =
        '<div class="acct-head"><span class="acct-nick">' + (a.nickname || "?") + "</span>" +
        '<span class="badge ' + st + '">' + stText + "</span></div>" +
        '<div class="acct-row">积分 <b>' + a.credits + "</b></div>" +
        '<div class="acct-row">冷却至 ' + fmtTime(a.until) + "</div>" +
        '<div class="acct-row">上次成功 ' + fmtTime(a.last_success) + "</div>" +
        '<div class="acct-row">上次错误 ' + fmtTime(a.last_err) + "</div>" +
        '<div class="acct-uid">' + a.uid + "</div>";
      box.appendChild(div);
    });
    $("#statusMeta").textContent = "更新于 " + new Date().toLocaleTimeString();
  }

  function loadStatus() {
    if (!key) { toast("请先输入 API Key", true); return; }
    api("/status")
      .then(function (r) {
        if (r.status === 401) { toast("API Key 无效", true); return null; }
        if (!r.ok) { toast("请求失败 HTTP " + r.status, true); return null; }
        return r.json();
      })
      .then(function (d) { if (d) render(d); })
      .catch(function (e) { toast("网络错误: " + e.message, true); });
  }

  function bind() {
    $("#refreshStatus").addEventListener("click", loadStatus);
  }

  bindKey();
  bindCheckin();
  bindLogin();
  bind();
  if (key) loadStatus();
})();