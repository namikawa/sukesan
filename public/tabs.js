// 調整画面のタブ切替（カレンダー登録 / 複数カレンダー仮押さえ）。
// JS 無効時はタブを表示せず（is-hidden のまま）、両フォームを縦に並べて表示する。
// 表示制御は hidden 属性でなく Bulma の .is-hidden（display:none !important）を使う
// （Bulma の display 指定が hidden 属性の UA スタイルを上書きするため）。
(function () {
  "use strict";
  var tabs = document.getElementById("mode-tabs");
  if (!tabs) return;

  var items = Array.prototype.slice.call(tabs.querySelectorAll("li[data-tab]"));

  function activate(id) {
    items.forEach(function (li) {
      var panel = document.getElementById(li.dataset.tab);
      var active = li.dataset.tab === id;
      li.classList.toggle("is-active", active);
      if (panel) panel.classList.toggle("is-hidden", !active);
    });
  }

  items.forEach(function (li) {
    li.addEventListener("click", function () { activate(li.dataset.tab); });
  });

  tabs.classList.remove("is-hidden");
  // サーバ側で is-active 指定されたタブ（入力復元時は仮押さえタブ）を初期表示にする。無ければ先頭。
  var initial = items.filter(function (li) { return li.classList.contains("is-active"); })[0] || items[0];
  activate(initial.dataset.tab);
})();
