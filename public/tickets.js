// ワンタイム URL 一覧（views/tickets.erb）専用の挙動。コピーボタンは共通の copy.js が担う。
(function () {
  "use strict";

  // 表示件数セレクトは選択即送信（JS 無効時は隣の「表示」ボタンで送信）。
  // submit() は submit イベントを発火させないため requestSubmit() を使う
  // （共通の二重送信ガード＝form-submit.js を通し、HTML5 の入力検証も尊重する）。
  var perSelect = document.querySelector(".per-select");
  if (perSelect && perSelect.form) {
    perSelect.addEventListener("change", function () { perSelect.form.requestSubmit(); });
  }
})();
