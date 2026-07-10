// API キー発行直後の「コピー」ボタン。対象要素（<code>）のテキストをクリップボードへコピーする。
// 通知ボックスが無い通常表示ではボタンが存在しないため、何もしない。
(function () {
  "use strict";

  var btn = document.getElementById("api-key-copy");
  if (!btn) return;

  var code = document.getElementById(btn.dataset.target);
  if (!code) return;

  function flash(message) {
    var original = btn.textContent;
    btn.textContent = message;
    btn.disabled = true;
    setTimeout(function () {
      btn.textContent = original;
      btn.disabled = false;
    }, 1500);
  }

  // フォールバック: キー要素のテキストを選択状態にする（手動コピー用）。
  function selectKeyText() {
    var range = document.createRange();
    range.selectNodeContents(code);
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  btn.addEventListener("click", function () {
    // navigator.clipboard は HTTPS / localhost（secure context）でのみ利用可能。失敗時は手動選択にフォールバック。
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(code.textContent).then(
        function () { flash("コピーしました"); },
        selectKeyText
      );
    } else {
      selectKeyText();
    }
  });
})();
