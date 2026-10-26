/* Runs before the app: shows a clear message on browsers that are too old
   (e.g. Internet Explorer) instead of a blank page. Written in ES3 on purpose. */
(function () {
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
