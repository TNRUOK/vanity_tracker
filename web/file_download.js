// Browser file download for Vanity Tracker backups (Flutter web).
// The object URL is revoked only after the browser has had time to start the download
// (revoking it immediately after click() can cancel the download in some browsers).
(function () {
  'use strict';

  window.vanityDownloadFile = function (bytes, fileName, mimeType) {
    if (!bytes || !bytes.length) throw new Error('No data to download.');
    var blob = new Blob([bytes], { type: mimeType || 'application/octet-stream' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = fileName;
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    setTimeout(function () {
      URL.revokeObjectURL(url);
      a.remove();
    }, 60000);
    return blob.size;
  };
})();
