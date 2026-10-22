/* Runs before the app: shows a clear message on browsers that are too old
   (e.g. Internet Explorer) instead of a blank page. Written in ES3 on purpose. */
(function () {
  // Apply the saved (or system) colour theme before first paint.
  try {
    var t = window.localStorage && localStorage.getItem('sqldash.theme');
    if (!t) t = window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    document.documentElement.setAttribute('data-theme', t);
  } catch (e) { /* storage unavailable */ }

  var ok = typeof window.fetch === 'function' && typeof window.Promise === 'function' &&
           window.CSS && CSS.supports && CSS.supports('--a', '0');
  if (ok) return;
  window.__unsupportedBrowser = true;
  function show() {
    var el = document.getElementById('unsupported');
    if (el) { el.removeAttribute('hidden'); el.style.display = 'block'; }
  }
  if (document.readyState === 'loading') {
    document.attachEvent ? document.attachEvent('onreadystatechange', function () {
      if (document.readyState !== 'loading') show();
    }) : document.addEventListener('DOMContentLoaded', show);
  } else { show(); }
})();
