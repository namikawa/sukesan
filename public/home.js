// 開始日を変更したら、終了日が開始日以降になるよう追従させる。
(function () {
  "use strict";
  var start = document.getElementById("start-date");
  var end = document.getElementById("end-date");
  if (!start || !end) return;

  function sync() {
    // 日付入力は "YYYY-MM-DD" 形式なので辞書順比較で日付の前後を判定できる。
    end.min = start.value;
    if (end.value < start.value) {
      end.value = start.value;
    }
  }

  start.addEventListener("change", sync);
  sync();
})();
