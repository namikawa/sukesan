// コピー・ボタン（.copy-btn）。data-target で指定した要素の内容をクリップボードへコピーする。
// input（value を持ち select() できる要素）は value を、それ以外（<code> 等）は textContent を対象にする。
// CSP（script-src 'self'）維持のため外部ファイルとして読み込む（インライン不可）。
(function () {
  "use strict";

  function flash(btn, message) {
    var original = btn.textContent;
    btn.textContent = message;
    btn.disabled = true;
    setTimeout(function () {
      btn.textContent = original;
      btn.disabled = false;
    }, 1500);
  }

  // 対象要素を選択状態にする。input は select()、それ以外（<code> 等）は Range で内容を選択する。
  function selectTarget(target, isInput) {
    if (isInput) {
      target.select();
      return;
    }
    var range = document.createRange();
    range.selectNodeContents(target);
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  // navigator.clipboard が使えないときのフォールバック。テキストを選択状態にし、
  // execCommand("copy") を試みて成功なら flash する。
  function fallbackCopy(btn, target, isInput) {
    selectTarget(target, isInput);
    if (document.execCommand("copy")) {
      flash(btn, "コピーしました");
    }
  }

  function copy(btn) {
    var target = document.getElementById(btn.dataset.target);
    if (!target) return;

    var isInput = typeof target.select === "function" && "value" in target;
    var text = isInput ? target.value : target.textContent;

    // navigator.clipboard は HTTPS / localhost（secure context）でのみ利用可能。
    // 失敗・非対応時は手動選択＋execCommand のフォールバックに切り替える。
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { flash(btn, "コピーしました"); },
        function () { fallbackCopy(btn, target, isInput); }
      );
    } else {
      fallbackCopy(btn, target, isInput);
    }
  }

  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () { copy(btn); });
  });
})();
