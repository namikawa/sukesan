// 仮押さえフォームのチェックボックス制御。上限（data-max-holds）に達したら未チェックの
// ボックスを無効化し、選択数を表示する。JS 無効時はサーバ側の検証（上限超過は警告通知）が働く。
(function () {
  "use strict";
  var form = document.getElementById("hold-form");
  if (!form) return;

  var max = parseInt(form.dataset.maxHolds, 10) || 5;
  var counter = document.getElementById("hold-count");
  var boxes = Array.prototype.slice.call(form.querySelectorAll('input[name="slots[]"]'));

  function refresh() {
    var checked = boxes.filter(function (box) { return box.checked; }).length;
    boxes.forEach(function (box) {
      box.disabled = !box.checked && checked >= max;
    });
    if (counter) counter.textContent = checked + " / " + max + " 件選択中";
  }

  boxes.forEach(function (box) { box.addEventListener("change", refresh); });
  refresh(); // 入力復元（サーバ側でチェック済み）にも初期表示で追従する
})();
