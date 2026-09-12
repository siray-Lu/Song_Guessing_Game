/* 黑膠猜歌 — Service Worker
   存在的目的只有兩個：
   1. 讓瀏覽器認定這是可安裝的 PWA（Chrome 要求必須有 fetch 事件處理）
   2. 完全離線時給一個能開起來的畫面

   刻意採用「網路優先」：這個遊戲的歌都靠 YouTube 串流，離線本來就玩不了，
   所以沒必要為了離線去快取內容。更重要的是，快取優先會讓我 push 更新後
   使用者還看到舊版本 —— 那會毀掉「改完重新整理就生效」這個最大優點。
*/

const CACHE = 'vinyl-quiz-v1';
// 只留最低限度的殼，離線時至少開得起來
const SHELL = ['./', './index.html', './manifest.json', './icon-192.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).catch(() => {}).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  // 只管自己網域的 GET；YouTube、Cloudflare Workers 的請求一律不要插手
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;

  e.respondWith(
    fetch(req)
      .then((res) => {
        // 順手把最新版本存起來，純粹當離線時的後備
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
        }
        return res;
      })
      .catch(() =>
        caches.match(req).then((hit) => hit || caches.match('./index.html'))
      )
  );
});
