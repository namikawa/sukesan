// 送信ボタンの二重押し防止と処理中表示。外部カレンダー API を叩く画面（スケジュール同期・
// 空き時間チェック・予約・仮押さえ）は応答まで数秒〜数十秒かかるため、押されたボタンを
// 無効化＋スピナー表示にし、同じページの他の送信ボタンも処理が終わるまで押せなくする。
// ページごとに書かず document の submit イベント委譲で一括して扱う。
// CSP（script-src 'self'）維持のため外部ファイルとして読み込む（インライン不可）。
(function () {
  "use strict";

  var PENDING_MESSAGE = "処理中です。しばらくお待ちください。";
  var LOCKED_ATTR = "data-submit-locked"; // このスクリプトが無効化したボタンの目印
  var MESSAGE_CLASS = "submit-pending-message"; // 挿入した案内文の識別子（削除用）

  // ページ内で送信が始まったら、フォームをまたいで以降の送信を止める。フォーム単位で
  // 持つと、ボタン無効化までの隙間（次のタスクまで）に別フォームの送信が通ってしまう
  // （決定画面は候補ごとに削除フォームが分かれており、別 slot への 2 件が両方成立する）。
  var submitting = false;

  // e.submitter が取れないブラウザ向けのフォールバック。決定画面のボタンやラジオは
  // form 属性で別の form 要素に紐づいており子孫ではないため、querySelector でなく
  // form 属性による関連付けも含む form.elements から探す。
  function fallbackSubmitter(form) {
    return Array.prototype.slice.call(form.elements).filter(function (el) {
      return el.type === "submit";
    })[0];
  }

  function showPendingMessage(button) {
    var message = document.createElement("p");
    message.className = MESSAGE_CLASS + " is-size-7 has-text-grey mt-2";
    message.setAttribute("aria-live", "polite");
    message.textContent = PENDING_MESSAGE;
    button.insertAdjacentElement("afterend", message);
  }

  function lock(form, button) {
    document.querySelectorAll('button[type="submit"], input[type="submit"]')
      .forEach(function (el) {
        if (el.disabled) return; // 元から無効なボタン（Google 未連携・ページ送り）は触らない
        el.setAttribute(LOCKED_ATTR, "");
        el.disabled = true;
      });
    if (!button) return;

    button.classList.add("is-loading");
    // 待ち時間が長い操作（data-pending）だけ、押したボタンの直後に案内文を出す。
    if (form.hasAttribute("data-pending")) showPendingMessage(button);
  }

  document.addEventListener("submit", function (e) {
    // 二重送信のガード。フラグは同期的に立てる（ボタン無効化前の再送信も止めるため）。
    if (submitting) {
      e.preventDefault();
      return;
    }
    submitting = true;

    var form = e.target;
    form.setAttribute("aria-busy", "true");

    var button = e.submitter || fallbackSubmitter(form);
    // 無効化は次のタスクへ回す（submit イベント内で同期的に disabled にすると、
    // name 付き送信ボタンの値が送信されないブラウザがあるため）。
    setTimeout(function () { lock(form, button); }, 0);
  });

  // 「戻る」で bfcache から復帰したページは送信中の状態が残るので元に戻す
  // （フラグを戻し忘れると、復帰したページから二度と送信できなくなる）。
  window.addEventListener("pageshow", function (e) {
    if (!e.persisted) return;

    submitting = false;
    document.querySelectorAll("[" + LOCKED_ATTR + "]").forEach(function (el) {
      el.removeAttribute(LOCKED_ATTR);
      el.disabled = false;
      el.classList.remove("is-loading");
    });
    document.querySelectorAll("." + MESSAGE_CLASS).forEach(function (el) { el.remove(); });
    document.querySelectorAll("[aria-busy]").forEach(function (el) {
      el.removeAttribute("aria-busy");
    });
  });
})();
