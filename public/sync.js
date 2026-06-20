// /sync の「すべて選択」チェックボックスで未反映の行をまとめて選択する。
(function () {
  "use strict";
  var all = document.getElementById("select-all");
  if (!all) return;

  all.addEventListener("change", function (e) {
    document.querySelectorAll('input[name="selected[]"]:not([disabled])')
      .forEach(function (cb) { cb.checked = e.target.checked; });
  });
})();
