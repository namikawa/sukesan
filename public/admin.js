// ワンタイム URL の「コピー」ボタン。対象 input の値をクリップボードへコピーする。
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

  function copy(btn) {
    var input = document.getElementById(btn.dataset.target);
    if (!input) return;

    // navigator.clipboard は HTTPS / localhost でのみ利用可能。失敗時は手動選択にフォールバック。
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(input.value).then(
        function () { flash(btn, "コピーしました"); },
        function () { input.select(); }
      );
    } else {
      input.select();
      document.execCommand("copy");
      flash(btn, "コピーしました");
    }
  }

  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () { copy(btn); });
  });

  // 表示件数セレクトは選択即送信（JS 無効時は隣の「表示」ボタンで送信）。
  var perSelect = document.querySelector(".per-select");
  if (perSelect && perSelect.form) {
    perSelect.addEventListener("change", function () { perSelect.form.submit(); });
  }
})();
